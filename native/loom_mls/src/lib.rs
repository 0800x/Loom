//! Native RFC 9420 core. Delivery metadata is untrusted; callers supply pinned
//! device credentials. Persistence contains secrets and is AEAD sealed.
use chacha20poly1305::{
    aead::{Aead, Payload},
    ChaCha20Poly1305, KeyInit,
};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use tls_codec::{Deserialize as _, Serialize as _};
use zeroize::Zeroizing;

pub mod ffi;

pub const PROTOCOL: &str = "Loom-MLS-v1";
const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
pub type Result<T> = std::result::Result<T, String>;
fn error(e: impl std::fmt::Debug) -> String {
    format!("MLS operation rejected: {e:?}")
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DevicePin {
    pub device_id: Vec<u8>,
    pub signature_key: Vec<u8>,
}
#[derive(Serialize, Deserialize)]
struct Snapshot {
    version: u8,
    device: Vec<u8>,
    signer: SignatureKeyPair,
    records: Vec<(Vec<u8>, Vec<u8>)>,
}
pub struct Engine {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
}
#[derive(Serialize, Deserialize)]
pub struct Commit {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub epoch: u64,
}
#[derive(Serialize, Deserialize)]
pub enum Received {
    Application {
        sender: Vec<u8>,
        plaintext: Vec<u8>,
    },
    Commit {
        sender: Vec<u8>,
        epoch: u64,
        active: bool,
    },
}
impl Engine {
    pub fn new(device_id: Vec<u8>) -> Result<Self> {
        if device_id.is_empty() || device_id.len() > 128 {
            return Err("Invalid device id".into());
        }
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).map_err(error)?;
        signer.store(provider.storage()).map_err(error)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(device_id).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
        })
    }
    pub fn pin(&self) -> DevicePin {
        DevicePin {
            device_id: self.credential.credential.serialized_content().to_vec(),
            signature_key: self.signer.to_public_vec(),
        }
    }
    pub fn key_package(&self) -> Result<Vec<u8>> {
        KeyPackage::builder()
            .build(SUITE, &self.provider, &self.signer, self.credential.clone())
            .map_err(error)?
            .key_package()
            .tls_serialize_detached()
            .map_err(error)
    }
    fn package(&self, bytes: &[u8], pin: &DevicePin) -> Result<KeyPackage> {
        let kp = KeyPackageIn::tls_deserialize_exact(bytes)
            .map_err(error)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(error)?;
        let leaf = kp.leaf_node();
        if leaf.credential().serialized_content() != pin.device_id
            || leaf.signature_key().as_slice() != pin.signature_key
        {
            return Err("Untrusted key package credential".into());
        }
        Ok(kp)
    }
    fn group(&self, id: &[u8]) -> Result<MlsGroup> {
        MlsGroup::load(self.provider.storage(), &GroupId::from_slice(id))
            .map_err(error)?
            .ok_or("Unknown group".into())
    }
    /// A room-specific MLS exporter. Pending/stale epochs cannot start media.
    pub fn export_call_key(&self, id: &[u8], context: &[u8], epoch: u64) -> Result<Vec<u8>> {
        let room = context.strip_prefix(b"Loom-GroupCall-v1:").ok_or("Invalid call context")?;
        if room.len() != 36 || room.iter().enumerate().any(|(i,b)|
            if [8,13,18,23].contains(&i) { *b != b'-' } else { !b.is_ascii_hexdigit() }) {
            return Err("Invalid call context".into());
        }
        let group = self.group(id)?;
        if !group.is_active() || group.pending_commit().is_some() || group.epoch().as_u64() != epoch {
            return Err("Group call epoch changed".into());
        }
        group.export_secret(self.provider.crypto(), "Loom-GroupCall-v1", context, 32).map_err(error)
    }
    fn check_roster(group: &MlsGroup, pins: &[DevicePin]) -> Result<()> {
        let members: Vec<_> = group.members().collect();
        if members.len() != pins.len()
            || pins
                .iter()
                .enumerate()
                .any(|(i, p)| pins[..i].iter().any(|old| old.device_id == p.device_id))
        {
            return Err("Roster mismatch".into());
        }
        for m in members {
            if !pins.iter().any(|p| {
                p.device_id == m.credential.serialized_content()
                    && p.signature_key == m.signature_key
            }) {
                return Err("Untrusted group member".into());
            }
        }
        Ok(())
    }
    pub fn create(&self, id: &[u8]) -> Result<()> {
        if id.is_empty()
            || id.len() > 128
            || MlsGroup::load(self.provider.storage(), &GroupId::from_slice(id))
                .map_err(error)?
                .is_some()
        {
            return Err("Invalid or existing group".into());
        }
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(SUITE)
            .use_ratchet_tree_extension(true)
            .max_past_epochs(2)
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .build();
        MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &config,
            GroupId::from_slice(id),
            self.credential.clone(),
        )
        .map_err(error)?;
        Ok(())
    }
    // Pending commits must be persisted with the exact delivery request. Merge
    // only after the server CAS receipt; conflicts restore the prior snapshot.
    pub fn add(&self, id: &[u8], packages: &[(Vec<u8>, DevicePin)]) -> Result<Commit> {
        let packages = packages
            .iter()
            .map(|(b, p)| self.package(b, p))
            .collect::<Result<Vec<_>>>()?;
        let mut group = self.group(id)?;
        let (commit, welcome, _) = group
            .add_members(&self.provider, &self.signer, &packages)
            .map_err(error)?;
        Ok(Commit {
            commit: commit.tls_serialize_detached().map_err(error)?,
            welcome: Some(welcome.tls_serialize_detached().map_err(error)?),
            epoch: group.epoch().as_u64() + 1,
        })
    }
    pub fn rotate(&self, id: &[u8]) -> Result<Commit> {
        let mut group = self.group(id)?;
        let bundle = group
            .self_update(&self.provider, &self.signer, LeafNodeParameters::default())
            .map_err(error)?;
        Ok(Commit {
            commit: bundle.commit().tls_serialize_detached().map_err(error)?,
            welcome: bundle
                .to_welcome_msg()
                .map(|w| w.tls_serialize_detached())
                .transpose()
                .map_err(error)?,
            epoch: group.epoch().as_u64() + 1,
        })
    }
    pub fn remove(&self, id: &[u8], device_ids: &[Vec<u8>]) -> Result<Commit> {
        let mut group = self.group(id)?;
        let indices = device_ids
            .iter()
            .map(|id| {
                group
                    .members()
                    .find(|m| m.credential.serialized_content() == id)
                    .map(|m| m.index)
                    .ok_or("Unknown member".into())
            })
            .collect::<Result<Vec<_>>>()?;
        let (commit, welcome, _) = group
            .remove_members(&self.provider, &self.signer, &indices)
            .map_err(error)?;
        Ok(Commit {
            commit: commit.tls_serialize_detached().map_err(error)?,
            welcome: welcome
                .map(|w| w.tls_serialize_detached())
                .transpose()
                .map_err(error)?,
            epoch: group.epoch().as_u64() + 1,
        })
    }
    pub fn accept_pending(&self, id: &[u8], pins: &[DevicePin]) -> Result<u64> {
        let mut group = self.group(id)?;
        group.merge_pending_commit(&self.provider).map_err(error)?;
        Self::check_roster(&group, pins)?;
        Ok(group.epoch().as_u64())
    }
    pub fn join(&self, id: &[u8], welcome: &[u8], pins: &[DevicePin]) -> Result<u64> {
        if MlsGroup::load(self.provider.storage(), &GroupId::from_slice(id))
            .map_err(error)?
            .is_some()
        {
            return Err("Group already exists".into());
        }
        let welcome = match MlsMessageIn::tls_deserialize_exact(welcome)
            .map_err(error)?
            .extract()
        {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Expected Welcome".into()),
        };
        let config = MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .max_past_epochs(2)
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .build();
        let staged = StagedWelcome::new_from_welcome(&self.provider, &config, welcome, None)
            .map_err(error)?;
        if staged.group_context().group_id().as_slice() != id {
            return Err("Welcome group mismatch".into());
        }
        let group = staged.into_group(&self.provider).map_err(error)?;
        Self::check_roster(&group, pins)?;
        Ok(group.epoch().as_u64())
    }
    pub fn encrypt(&self, id: &[u8], plaintext: &[u8]) -> Result<(u64, Vec<u8>)> {
        if plaintext.is_empty() || plaintext.len() > 512 * 1024 {
            return Err("Invalid plaintext size".into());
        }
        let mut group = self.group(id)?;
        let message = group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(error)?;
        Ok((
            group.epoch().as_u64(),
            message.tls_serialize_detached().map_err(error)?,
        ))
    }
    pub fn receive(&self, id: &[u8], wire: &[u8], pins: &[DevicePin]) -> Result<Received> {
        let mut group = self.group(id)?;
        let message = MlsMessageIn::tls_deserialize_exact(wire)
            .map_err(error)?
            .try_into_protocol_message()
            .map_err(error)?;
        let processed = group
            .process_message(&self.provider, message)
            .map_err(error)?;
        let sender = processed.credential().serialized_content().to_vec();
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(m) => Ok(Received::Application {
                sender,
                plaintext: m.into_bytes(),
            }),
            ProcessedMessageContent::StagedCommitMessage(c) => {
                group
                    .merge_staged_commit(&self.provider, *c)
                    .map_err(error)?;
                let active = group.is_active();
                Self::check_roster(&group, pins)?;
                Ok(Received::Commit {
                    sender,
                    epoch: group.epoch().as_u64(),
                    active,
                })
            }
            _ => Err("Standalone proposals are not supported".into()),
        }
    }
    /// State is bound to device and a storage generation. The caller's database
    /// CAS must prevent replaying an old valid blob (AEAD alone cannot do that).
    pub fn seal(&self, key: &[u8; 32], generation: u64) -> Result<Vec<u8>> {
        let records = self
            .provider
            .storage()
            .values
            .read()
            .map_err(error)?
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let mut snapshot = Snapshot {
            version: 1,
            device: self.pin().device_id,
            signer: self.signer.clone(),
            records,
        };
        let plain = Zeroizing::new(serde_json::to_vec(&snapshot).map_err(error)?);
        for (k, v) in &mut snapshot.records {
            use zeroize::Zeroize;
            k.zeroize();
            v.zeroize();
        }
        let mut nonce = [0u8; 12];
        rand::rngs::OsRng.fill_bytes(&mut nonce);
        let aad = self.aad(generation);
        let mut result = nonce.to_vec();
        result.extend(
            ChaCha20Poly1305::new(key.into())
                .encrypt(
                    (&nonce).into(),
                    Payload {
                        msg: &plain,
                        aad: &aad,
                    },
                )
                .map_err(error)?,
        );
        Ok(result)
    }
    fn aad(&self, generation: u64) -> Vec<u8> {
        Self::binding(&self.pin().device_id, generation)
    }
    fn binding(device: &[u8], generation: u64) -> Vec<u8> {
        let mut aad = PROTOCOL.as_bytes().to_vec();
        aad.extend_from_slice(&generation.to_be_bytes());
        aad.extend_from_slice(device);
        aad
    }
    pub fn restore(blob: &[u8], key: &[u8; 32], device: &[u8], generation: u64) -> Result<Self> {
        if blob.len() < 28 || blob.len() > 32 * 1024 * 1024 {
            return Err("Invalid sealed state".into());
        }
        let plain = Zeroizing::new(
            ChaCha20Poly1305::new(key.into())
                .decrypt(
                    (&blob[..12]).into(),
                    Payload {
                        msg: &blob[12..],
                        aad: &Self::binding(device, generation),
                    },
                )
                .map_err(error)?,
        );
        let snapshot: Snapshot = serde_json::from_slice(&plain).map_err(error)?;
        if snapshot.version != 1 || snapshot.device != device {
            return Err("State device mismatch".into());
        }
        let provider = OpenMlsRustCrypto::default();
        *provider.storage().values.write().map_err(error)? = snapshot.records.into_iter().collect();
        let credential = CredentialWithKey {
            credential: BasicCredential::new(snapshot.device).into(),
            signature_key: snapshot.signer.to_public_vec().into(),
        };
        Ok(Self {
            provider,
            signer: snapshot.signer,
            credential,
        })
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        if let Ok(mut values) = self.provider.storage().values.write() {
            use zeroize::Zeroize;
            for (mut k, mut v) in values.drain() {
                k.zeroize();
                v.zeroize();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn call_exporter_binds_room_epoch_and_active_membership() {
        let a = Engine::new(b"a".to_vec()).unwrap();
        let b = Engine::new(b"b".to_vec()).unwrap();
        let id = b"g";
        let context = b"Loom-GroupCall-v1:12345678-1234-1234-1234-123456789abc";
        let other = b"Loom-GroupCall-v1:12345678-1234-1234-1234-123456789abd";
        a.create(id).unwrap();
        let pins = [a.pin(), b.pin()];
        let add = a.add(id, &[(b.key_package().unwrap(),b.pin())]).unwrap();
        assert!(a.export_call_key(id,context,0).is_err());
        a.accept_pending(id,&pins).unwrap();
        b.join(id,add.welcome.as_ref().unwrap(),&pins).unwrap();
        let key = a.export_call_key(id,context,1).unwrap();
        assert_eq!(key.len(),32);
        assert_eq!(key,b.export_call_key(id,context,1).unwrap());
        assert_ne!(key,a.export_call_key(id,other,1).unwrap());
        assert!(a.export_call_key(id,context,0).is_err());
        assert!(a.export_call_key(id,b"bad",1).is_err());
        let remove = a.remove(id,&[b"b".to_vec()]).unwrap();
        assert!(a.export_call_key(id,context,1).is_err());
        a.accept_pending(id,&[a.pin()]).unwrap();
        b.receive(id,&remove.commit,&[a.pin()]).unwrap();
        assert!(b.export_call_key(id,context,2).is_err());
        assert_ne!(key,a.export_call_key(id,context,2).unwrap());
    }
    #[test]
    fn membership_encryption_replay_removal_and_restart() {
        let a = Engine::new(b"alice".to_vec()).unwrap();
        let b = Engine::new(b"bob".to_vec()).unwrap();
        let c = Engine::new(b"carol".to_vec()).unwrap();
        let id = b"group-1";
        a.create(id).unwrap();
        let pins = vec![a.pin(), b.pin()];
        let add = a.add(id, &[(b.key_package().unwrap(), b.pin())]).unwrap();
        assert_eq!(a.accept_pending(id, &pins).unwrap(), 1);
        b.join(id, add.welcome.as_ref().unwrap(), &pins).unwrap();
        let (_, wire) = a.encrypt(id, b"hello").unwrap();
        match b.receive(id, &wire, &pins).unwrap() {
            Received::Application { plaintext, .. } => assert_eq!(plaintext, b"hello"),
            _ => panic!(),
        }
        assert!(b.receive(id, &wire, &pins).is_err());
        let key = [7u8; 32];
        let sealed = b.seal(&key, 9).unwrap();
        assert!(Engine::restore(&sealed, &key, b"bob", 8).is_err());
        assert!(Engine::restore(&sealed, &[8; 32], b"bob", 9).is_err());
        let b = Engine::restore(&sealed, &key, b"bob", 9).unwrap();
        let pins3 = vec![a.pin(), b.pin(), c.pin()];
        let add = a.add(id, &[(c.key_package().unwrap(), c.pin())]).unwrap();
        a.accept_pending(id, &pins3).unwrap();
        b.receive(id, &add.commit, &pins3).unwrap();
        c.join(id, add.welcome.as_ref().unwrap(), &pins3).unwrap();
        let pins2 = vec![a.pin(), c.pin()];
        let remove = a.remove(id, &[b"bob".to_vec()]).unwrap();
        a.accept_pending(id, &pins2).unwrap();
        c.receive(id, &remove.commit, &pins2).unwrap();
        let (_, wire) = a.encrypt(id, b"after removal").unwrap();
        assert!(b.receive(id, &wire, &pins2).is_err());
        assert!(matches!(
            c.receive(id, &wire, &pins2).unwrap(),
            Received::Application { .. }
        ));
    }
    #[test]
    fn key_package_must_match_pinned_device() {
        let a = Engine::new(b"a".to_vec()).unwrap();
        let b = Engine::new(b"b".to_vec()).unwrap();
        a.create(b"g").unwrap();
        assert!(a.add(b"g", &[(b.key_package().unwrap(), a.pin())]).is_err());
    }
}
