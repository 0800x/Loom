//! Non-shipping proof of concept for the Loom Architecture-v2 session-provider
//! evaluation.
//!
//! This crate pins vodozemac 0.10.0 and executable-tests the upstream Olm
//! account/session semantics that a reviewed `LoomSessionCryptoProvider`
//! adapter would need to compose safely.
//!
//! The legacy validation ABI remains available for existing PoC tests. The
//! second ABI in `ffi_v2` moves sensitive Account/Session state behind opaque
//! native handles and crosses the persistence boundary only as owned byte
//! buffers which are zeroed before native release. It is a substantially safer
//! candidate bridge, but still requires platform packaging and independent
//! review before production enablement.
//!
//! Inbound session creation mutates the local Account and consumes a one-time
//! key. Loom therefore persists the returned protected Account state and the
//! new Session state atomically through its crypto-state transaction.

mod ffi;
mod ffi_v2;

#[cfg(test)]
mod tests {
    use anyhow::{bail, Result};
    use vodozemac::olm::{
        Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle,
    };

    fn establish_pair() -> Result<(Account, Account, Session, Session)> {
        let alice = Account::new();
        let mut bob = Account::new();
        bob.generate_one_time_keys(1);
        let bob_otk = *bob
            .one_time_keys()
            .values()
            .next()
            .ok_or_else(|| anyhow::anyhow!("Bob did not produce a one-time key"))?;

        let mut alice_session = alice.create_outbound_session(
            SessionConfig::version_1(),
            bob.curve25519_key(),
            bob_otk,
        )?;
        bob.mark_keys_as_published();

        let first_plaintext = b"loom-v2-provider-poc-first-message";
        let first = alice_session.encrypt(first_plaintext)?;
        let prekey = match first {
            OlmMessage::PreKey(message) => message,
            OlmMessage::Normal(_) => {
                bail!("new outbound Olm session did not emit a pre-key message")
            }
        };
        let inbound = bob.create_inbound_session(
            SessionConfig::version_1(),
            alice.curve25519_key(),
            &prekey,
        )?;
        if inbound.plaintext != first_plaintext {
            bail!("inbound pre-key plaintext mismatch");
        }
        if alice_session.session_id() != inbound.session.session_id() {
            bail!("Olm session IDs differ after asynchronous establishment");
        }

        Ok((alice, bob, alice_session, inbound.session))
    }

    #[test]
    fn asynchronous_prekey_round_trip_and_reply() -> Result<()> {
        let (_alice, _bob, mut alice_session, mut bob_session) = establish_pair()?;

        let reply = b"loom-v2-provider-poc-reply";
        let encrypted_reply: OlmMessage = bob_session.encrypt(reply)?;
        let decrypted = alice_session.decrypt(&encrypted_reply)?;
        assert_eq!(decrypted, reply);
        assert!(alice_session.has_received_message());
        assert!(bob_session.has_received_message());
        Ok(())
    }

    #[test]
    fn account_and_session_pickles_survive_restart_boundary() -> Result<()> {
        let (alice, bob, mut alice_session, mut bob_session) = establish_pair()?;

        let alice_account_json = serde_json::to_vec(&alice.pickle())?;
        let bob_account_json = serde_json::to_vec(&bob.pickle())?;
        let alice_session_json = serde_json::to_vec(&alice_session.pickle())?;
        let bob_session_json = serde_json::to_vec(&bob_session.pickle())?;

        let alice_restored: Account =
            serde_json::from_slice::<AccountPickle>(&alice_account_json)?.into();
        let bob_restored: Account =
            serde_json::from_slice::<AccountPickle>(&bob_account_json)?.into();
        let mut alice_session_restored = Session::from_pickle(serde_json::from_slice::<
            SessionPickle,
        >(&alice_session_json)?);
        let mut bob_session_restored =
            Session::from_pickle(serde_json::from_slice::<SessionPickle>(&bob_session_json)?);

        assert_eq!(alice.identity_keys(), alice_restored.identity_keys());
        assert_eq!(bob.identity_keys(), bob_restored.identity_keys());
        assert_eq!(
            alice_session.session_id(),
            alice_session_restored.session_id()
        );
        assert_eq!(bob_session.session_id(), bob_session_restored.session_id());

        let after_restart = b"after-restart";
        let encrypted: OlmMessage = alice_session_restored.encrypt(after_restart)?;
        assert_eq!(bob_session_restored.decrypt(&encrypted)?, after_restart);

        let original = b"original-live-session";
        let encrypted_original: OlmMessage = alice_session.encrypt(original)?;
        assert_eq!(bob_session.decrypt(&encrypted_original)?, original);
        Ok(())
    }

    #[test]
    fn inbound_session_creation_consumes_published_one_time_key() -> Result<()> {
        let alice = Account::new();
        let mut bob = Account::new();
        bob.generate_one_time_keys(1);
        let bob_otk = *bob
            .one_time_keys()
            .values()
            .next()
            .ok_or_else(|| anyhow::anyhow!("missing Bob one-time key"))?;
        bob.mark_keys_as_published();
        let before = bob.stored_one_time_key_count();
        assert_eq!(before, 1);

        let mut alice_session = alice.create_outbound_session(
            SessionConfig::version_1(),
            bob.curve25519_key(),
            bob_otk,
        )?;
        let first = alice_session.encrypt(b"consume-one-time-key")?;
        let prekey = match first {
            OlmMessage::PreKey(message) => message,
            OlmMessage::Normal(_) => bail!("expected pre-key message"),
        };
        let inbound = bob.create_inbound_session(
            SessionConfig::version_1(),
            alice.curve25519_key(),
            &prekey,
        )?;
        assert_eq!(inbound.plaintext, b"consume-one-time-key");
        assert_eq!(bob.stored_one_time_key_count(), before - 1);
        Ok(())
    }

    #[test]
    fn established_session_accepts_bounded_out_of_order_delivery() -> Result<()> {
        let (_alice, _bob, mut alice_session, mut bob_session) = establish_pair()?;

        let handshake_reply: OlmMessage = bob_session.encrypt(b"ready")?;
        assert_eq!(alice_session.decrypt(&handshake_reply)?, b"ready");

        let m12: OlmMessage = alice_session.encrypt(b"message-12")?;
        let m13: OlmMessage = alice_session.encrypt(b"message-13")?;
        let m14: OlmMessage = alice_session.encrypt(b"message-14")?;

        assert_eq!(bob_session.decrypt(&m14)?, b"message-14");
        assert_eq!(bob_session.decrypt(&m12)?, b"message-12");
        assert_eq!(bob_session.decrypt(&m13)?, b"message-13");
        Ok(())
    }

    /// Characterizes an important upstream vodozemac 0.10.0 policy rather than
    /// pretending Loom can configure it. The receiver chain retains only the
    /// newest 40 skipped message keys. If 41 messages are skipped, the oldest
    /// skipped message becomes undecryptable while the next one is still kept.
    ///
    /// This is a production-provider selection gate for a DTN messenger: packet
    /// routing must not promise arbitrarily delayed reordering that the selected
    /// session implementation cannot actually decrypt.
    #[test]
    fn skipped_key_window_is_forty_per_receiving_chain() -> Result<()> {
        let (_alice, _bob, mut alice_session, mut bob_session) = establish_pair()?;

        let handshake_reply: OlmMessage = bob_session.encrypt(b"ready")?;
        assert_eq!(alice_session.decrypt(&handshake_reply)?, b"ready");

        let mut messages = Vec::new();
        for index in 0..42 {
            let plaintext = format!("gap-message-{index:02}");
            let encrypted: OlmMessage = alice_session.encrypt(plaintext.as_bytes())?;
            messages.push((plaintext.into_bytes(), encrypted));
        }

        assert_eq!(
            bob_session.decrypt(&messages[41].1)?,
            messages[41].0.as_slice()
        );
        assert!(
            bob_session.decrypt(&messages[0].1).is_err(),
            "the oldest of 41 skipped messages should exceed vodozemac's retained-key window"
        );
        assert_eq!(
            bob_session.decrypt(&messages[1].1)?,
            messages[1].0.as_slice()
        );
        Ok(())
    }
}
