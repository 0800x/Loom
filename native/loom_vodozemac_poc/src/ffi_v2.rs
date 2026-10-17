use serde_json::{json, Value};
use std::collections::HashMap;
use std::mem;
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use vodozemac::olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle};
use vodozemac::Curve25519PublicKey;

pub const ABI_VERSION: u32 = 2;
pub const STATUS_OK: i32 = 0;
pub const STATUS_INVALID_ARGUMENT: i32 = 1;
pub const STATUS_INVALID_HANDLE: i32 = 2;
pub const STATUS_INVALID_STATE: i32 = 3;
pub const STATUS_CRYPTO_FAILURE: i32 = 4;
pub const STATUS_SERIALIZATION_FAILURE: i32 = 5;
pub const STATUS_INTERNAL_FAILURE: i32 = 6;
const MAX_STATE_BYTES: usize = 4 * 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024 + 64 * 1024;
const MAX_PUBLIC_BYTES: usize = 256 * 1024;
const MAX_ONE_TIME_KEYS: usize = 100;

#[repr(C)]
pub struct LoomOwnedBufferV2 {
    pub ptr: *mut u8,
    pub len: usize,
    pub capacity: usize,
    pub status: i32,
}

impl LoomOwnedBufferV2 {
    fn ok(mut bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self {
                ptr: ptr::null_mut(),
                len: 0,
                capacity: 0,
                status: STATUS_OK,
            };
        }
        let result = Self {
            ptr: bytes.as_mut_ptr(),
            len: bytes.len(),
            capacity: bytes.capacity(),
            status: STATUS_OK,
        };
        mem::forget(bytes);
        result
    }

    fn error(status: i32) -> Self {
        Self {
            ptr: ptr::null_mut(),
            len: 0,
            capacity: 0,
            status,
        }
    }
}

#[repr(C)]
pub struct LoomHandleResultV2 {
    pub handle: u64,
    pub status: i32,
}

#[repr(C)]
pub struct LoomBoolResultV2 {
    pub value: u8,
    pub status: i32,
}

#[repr(C)]
pub struct LoomInboundResultV2 {
    pub session_handle: u64,
    pub plaintext: LoomOwnedBufferV2,
    pub status: i32,
}

enum NativeState {
    Account(Box<Account>),
    Session(Box<Session>),
}

static HANDLES: OnceLock<Mutex<HashMap<u64, NativeState>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn handles() -> &'static Mutex<HashMap<u64, NativeState>> {
    HANDLES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn insert_state(state: NativeState) -> Result<u64, i32> {
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    if handle == 0 {
        return Err(STATUS_INTERNAL_FAILURE);
    }
    let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
    map.insert(handle, state);
    Ok(handle)
}

/// SAFETY: callers must keep [ptr, ptr+len) readable for the duration of the
/// synchronous call. Returned slices never escape an exported operation.
fn read_input<'a>(ptr: *const u8, len: usize, max: usize) -> Result<&'a [u8], i32> {
    if ptr.is_null() || len == 0 || len > max {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

fn parse_public_key(ptr: *const u8, len: usize) -> Result<Curve25519PublicKey, i32> {
    let bytes = read_input(ptr, len, 4096)?;
    serde_json::from_slice(bytes).map_err(|_| STATUS_INVALID_ARGUMENT)
}

fn parse_message(ptr: *const u8, len: usize) -> Result<OlmMessage, i32> {
    let bytes = read_input(ptr, len, MAX_MESSAGE_BYTES)?;
    serde_json::from_slice(bytes).map_err(|_| STATUS_INVALID_ARGUMENT)
}

fn serialize_public_keys<'a>(
    keys: impl Iterator<Item = &'a Curve25519PublicKey>,
) -> Result<Vec<Value>, i32> {
    keys.map(|key| serde_json::to_value(key).map_err(|_| STATUS_SERIALIZATION_FAILURE))
        .collect()
}

fn account_public_inventory(account: &Account) -> Result<Vec<u8>, i32> {
    let one_time_keys = serialize_public_keys(account.one_time_keys().values())?;
    let fallback_keys = serialize_public_keys(account.fallback_key().values())?;
    serde_json::to_vec(&json!({
        "curve25519": serde_json::to_value(account.curve25519_key())
            .map_err(|_| STATUS_SERIALIZATION_FAILURE)?,
        "ed25519": serde_json::to_value(account.ed25519_key())
            .map_err(|_| STATUS_SERIALIZATION_FAILURE)?,
        "one_time_keys": one_time_keys,
        "fallback_keys": fallback_keys,
        "stored_one_time_key_count": account.stored_one_time_key_count(),
        "max_one_time_key_count": account.max_number_of_one_time_keys(),
    }))
    .map_err(|_| STATUS_SERIALIZATION_FAILURE)
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_buffer_free(buffer: LoomOwnedBufferV2) {
    if buffer.ptr.is_null() || buffer.capacity == 0 {
        return;
    }
    if buffer.len > buffer.capacity || buffer.capacity > MAX_STATE_BYTES * 2 {
        return;
    }
    unsafe {
        ptr::write_bytes(buffer.ptr, 0, buffer.capacity);
        drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.capacity));
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_handle_close(handle: u64) -> i32 {
    if handle == 0 {
        return STATUS_INVALID_HANDLE;
    }
    match handles().lock() {
        Ok(mut map) => {
            if map.remove(&handle).is_some() {
                STATUS_OK
            } else {
                STATUS_INVALID_HANDLE
            }
        }
        Err(_) => STATUS_INTERNAL_FAILURE,
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_account_new(one_time_key_count: usize) -> LoomHandleResultV2 {
    let result = std::panic::catch_unwind(|| {
        if one_time_key_count == 0 || one_time_key_count > MAX_ONE_TIME_KEYS {
            return Err(STATUS_INVALID_ARGUMENT);
        }
        let mut account = Account::new();
        account.generate_one_time_keys(one_time_key_count);
        insert_state(NativeState::Account(Box::new(account)))
    });
    match result {
        Ok(Ok(handle)) => LoomHandleResultV2 {
            handle,
            status: STATUS_OK,
        },
        Ok(Err(status)) => LoomHandleResultV2 { handle: 0, status },
        Err(_) => LoomHandleResultV2 {
            handle: 0,
            status: STATUS_INTERNAL_FAILURE,
        },
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_account_import(
    state_ptr: *const u8,
    state_len: usize,
) -> LoomHandleResultV2 {
    let result = std::panic::catch_unwind(|| {
        let bytes = read_input(state_ptr, state_len, MAX_STATE_BYTES)?;
        let pickle: AccountPickle =
            serde_json::from_slice(bytes).map_err(|_| STATUS_INVALID_STATE)?;
        insert_state(NativeState::Account(Box::new(pickle.into())))
    });
    match result {
        Ok(Ok(handle)) => LoomHandleResultV2 {
            handle,
            status: STATUS_OK,
        },
        Ok(Err(status)) => LoomHandleResultV2 { handle: 0, status },
        Err(_) => LoomHandleResultV2 {
            handle: 0,
            status: STATUS_INTERNAL_FAILURE,
        },
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_account_export(handle: u64) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let account = match map.get(&handle) {
            Some(NativeState::Account(account)) => account,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        serde_json::to_vec(&account.pickle()).map_err(|_| STATUS_SERIALIZATION_FAILURE)
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= MAX_STATE_BYTES => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_account_public_inventory(handle: u64) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let account = match map.get(&handle) {
            Some(NativeState::Account(account)) => account,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        account_public_inventory(account)
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= MAX_PUBLIC_BYTES => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_account_prepare_prekeys(
    handle: u64,
    target_one_time_key_count: usize,
    rotate_fallback: u8,
) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let account = match map.get_mut(&handle) {
            Some(NativeState::Account(account)) => account,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        let allowed_max = account.max_number_of_one_time_keys().min(MAX_ONE_TIME_KEYS);
        if target_one_time_key_count == 0 || target_one_time_key_count > allowed_max {
            return Err(STATUS_INVALID_ARGUMENT);
        }
        let stored = account.stored_one_time_key_count();
        if stored < target_one_time_key_count {
            account.generate_one_time_keys(target_one_time_key_count - stored);
        }
        if rotate_fallback != 0 {
            account.generate_fallback_key();
        }
        account_public_inventory(account)
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= MAX_PUBLIC_BYTES => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_account_mark_keys_published(handle: u64) -> i32 {
    let result = std::panic::catch_unwind(|| {
        let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let account = match map.get_mut(&handle) {
            Some(NativeState::Account(account)) => account,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        account.mark_keys_as_published();
        Ok(())
    });
    match result {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(status)) => status,
        Err(_) => STATUS_INTERNAL_FAILURE,
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_account_forget_previous_fallback(
    handle: u64,
) -> LoomBoolResultV2 {
    let result = std::panic::catch_unwind(|| {
        let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let account = match map.get_mut(&handle) {
            Some(NativeState::Account(account)) => account,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        Ok(account.forget_fallback_key())
    });
    match result {
        Ok(Ok(value)) => LoomBoolResultV2 {
            value: u8::from(value),
            status: STATUS_OK,
        },
        Ok(Err(status)) => LoomBoolResultV2 { value: 0, status },
        Err(_) => LoomBoolResultV2 {
            value: 0,
            status: STATUS_INTERNAL_FAILURE,
        },
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_session_import(
    state_ptr: *const u8,
    state_len: usize,
) -> LoomHandleResultV2 {
    let result = std::panic::catch_unwind(|| {
        let bytes = read_input(state_ptr, state_len, MAX_STATE_BYTES)?;
        let pickle: SessionPickle =
            serde_json::from_slice(bytes).map_err(|_| STATUS_INVALID_STATE)?;
        insert_state(NativeState::Session(Box::new(Session::from_pickle(pickle))))
    });
    match result {
        Ok(Ok(handle)) => LoomHandleResultV2 {
            handle,
            status: STATUS_OK,
        },
        Ok(Err(status)) => LoomHandleResultV2 { handle: 0, status },
        Err(_) => LoomHandleResultV2 {
            handle: 0,
            status: STATUS_INTERNAL_FAILURE,
        },
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_session_export(handle: u64) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let session = match map.get(&handle) {
            Some(NativeState::Session(session)) => session,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        serde_json::to_vec(&session.pickle()).map_err(|_| STATUS_SERIALIZATION_FAILURE)
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= MAX_STATE_BYTES => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[no_mangle]
pub extern "C" fn loom_vodozemac_v2_session_id(handle: u64) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
        let session = match map.get(&handle) {
            Some(NativeState::Session(session)) => session,
            _ => return Err(STATUS_INVALID_HANDLE),
        };
        Ok(session.session_id().as_bytes().to_vec())
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= 256 => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_create_outbound_session(
    account_handle: u64,
    remote_identity_ptr: *const u8,
    remote_identity_len: usize,
    remote_one_time_ptr: *const u8,
    remote_one_time_len: usize,
) -> LoomHandleResultV2 {
    let result = std::panic::catch_unwind(|| {
        let remote_identity = parse_public_key(remote_identity_ptr, remote_identity_len)?;
        let remote_one_time = parse_public_key(remote_one_time_ptr, remote_one_time_len)?;
        let session = {
            let map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
            let account = match map.get(&account_handle) {
                Some(NativeState::Account(account)) => account,
                _ => return Err(STATUS_INVALID_HANDLE),
            };
            account
                .create_outbound_session(
                    SessionConfig::version_1(),
                    remote_identity,
                    remote_one_time,
                )
                .map_err(|_| STATUS_CRYPTO_FAILURE)?
        };
        insert_state(NativeState::Session(Box::new(session)))
    });
    match result {
        Ok(Ok(handle)) => LoomHandleResultV2 {
            handle,
            status: STATUS_OK,
        },
        Ok(Err(status)) => LoomHandleResultV2 { handle: 0, status },
        Err(_) => LoomHandleResultV2 {
            handle: 0,
            status: STATUS_INTERNAL_FAILURE,
        },
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_create_inbound_session(
    account_handle: u64,
    remote_identity_ptr: *const u8,
    remote_identity_len: usize,
    message_ptr: *const u8,
    message_len: usize,
) -> LoomInboundResultV2 {
    let result = std::panic::catch_unwind(|| {
        let remote_identity = parse_public_key(remote_identity_ptr, remote_identity_len)?;
        let message = parse_message(message_ptr, message_len)?;
        let prekey = match message {
            OlmMessage::PreKey(value) => value,
            OlmMessage::Normal(_) => return Err(STATUS_INVALID_ARGUMENT),
        };
        let inbound = {
            let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
            let account = match map.get_mut(&account_handle) {
                Some(NativeState::Account(account)) => account,
                _ => return Err(STATUS_INVALID_HANDLE),
            };
            account
                .create_inbound_session(SessionConfig::version_1(), remote_identity, &prekey)
                .map_err(|_| STATUS_CRYPTO_FAILURE)?
        };
        let plaintext = inbound.plaintext;
        let session_handle = insert_state(NativeState::Session(Box::new(inbound.session)))?;
        Ok((session_handle, plaintext))
    });
    match result {
        Ok(Ok((session_handle, plaintext))) => LoomInboundResultV2 {
            session_handle,
            plaintext: LoomOwnedBufferV2::ok(plaintext),
            status: STATUS_OK,
        },
        Ok(Err(status)) => LoomInboundResultV2 {
            session_handle: 0,
            plaintext: LoomOwnedBufferV2::error(status),
            status,
        },
        Err(_) => LoomInboundResultV2 {
            session_handle: 0,
            plaintext: LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
            status: STATUS_INTERNAL_FAILURE,
        },
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_encrypt(
    session_handle: u64,
    plaintext_ptr: *const u8,
    plaintext_len: usize,
) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let plaintext = read_input(plaintext_ptr, plaintext_len, 1024 * 1024)?;
        let message: OlmMessage = {
            let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
            let session = match map.get_mut(&session_handle) {
                Some(NativeState::Session(session)) => session,
                _ => return Err(STATUS_INVALID_HANDLE),
            };
            session
                .encrypt(plaintext)
                .map_err(|_| STATUS_CRYPTO_FAILURE)?
        };
        serde_json::to_vec(&message).map_err(|_| STATUS_SERIALIZATION_FAILURE)
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= MAX_MESSAGE_BYTES => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_v2_decrypt(
    session_handle: u64,
    message_ptr: *const u8,
    message_len: usize,
) -> LoomOwnedBufferV2 {
    let result = std::panic::catch_unwind(|| {
        let message = parse_message(message_ptr, message_len)?;
        let plaintext = {
            let mut map = handles().lock().map_err(|_| STATUS_INTERNAL_FAILURE)?;
            let session = match map.get_mut(&session_handle) {
                Some(NativeState::Session(session)) => session,
                _ => return Err(STATUS_INVALID_HANDLE),
            };
            session
                .decrypt(&message)
                .map_err(|_| STATUS_CRYPTO_FAILURE)?
        };
        Ok(plaintext)
    });
    match result {
        Ok(Ok(bytes)) if bytes.len() <= 1024 * 1024 => LoomOwnedBufferV2::ok(bytes),
        Ok(Ok(_)) => LoomOwnedBufferV2::error(STATUS_SERIALIZATION_FAILURE),
        Ok(Err(status)) => LoomOwnedBufferV2::error(status),
        Err(_) => LoomOwnedBufferV2::error(STATUS_INTERNAL_FAILURE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sensitive_state_uses_handles_and_byte_exports() {
        let account = loom_vodozemac_v2_account_new(1);
        assert_eq!(account.status, STATUS_OK);
        assert_ne!(account.handle, 0);
        let inventory = loom_vodozemac_v2_account_prepare_prekeys(account.handle, 4, 1);
        assert_eq!(inventory.status, STATUS_OK);
        unsafe { loom_vodozemac_v2_buffer_free(inventory) };
        assert_eq!(
            loom_vodozemac_v2_account_mark_keys_published(account.handle),
            STATUS_OK
        );
        let exported = loom_vodozemac_v2_account_export(account.handle);
        assert_eq!(exported.status, STATUS_OK);
        assert!(!exported.ptr.is_null());
        assert!(exported.len > 0);
        unsafe { loom_vodozemac_v2_buffer_free(exported) };
        assert_eq!(loom_vodozemac_v2_handle_close(account.handle), STATUS_OK);
        assert_eq!(
            loom_vodozemac_v2_handle_close(account.handle),
            STATUS_INVALID_HANDLE
        );
    }
}
