use serde_json::{json, Value};
use std::ffi::{c_char, CString};
use std::ptr;
use std::slice;
use vodozemac::olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle};
use vodozemac::Curve25519PublicKey;

const ABI_VERSION: u64 = 1;
const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_ONE_TIME_KEYS: usize = 100;

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_poc_call(
    input: *const u8,
    input_len: usize,
) -> *mut c_char {
    let response = std::panic::catch_unwind(|| unsafe { handle_raw_request(input, input_len) })
        .unwrap_or_else(|_| error_response("panic"));
    let text = serde_json::to_string(&response)
        .unwrap_or_else(|_| "{\"ok\":false,\"error\":\"serialization_failed\"}".to_owned());
    match CString::new(text) {
        Ok(value) => value.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn loom_vodozemac_poc_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(value));
    }
}

unsafe fn handle_raw_request(input: *const u8, input_len: usize) -> Value {
    if input.is_null() || input_len == 0 || input_len > MAX_REQUEST_BYTES {
        return error_response("invalid_request");
    }
    let bytes = unsafe { slice::from_raw_parts(input, input_len) };
    let request: Value = match serde_json::from_slice(bytes) {
        Ok(value) => value,
        Err(_) => return error_response("invalid_json"),
    };
    match dispatch(&request) {
        Ok(value) => json!({"ok": true, "value": value}),
        Err(code) => error_response(code),
    }
}

fn dispatch(request: &Value) -> Result<Value, &'static str> {
    let op = string_field(request, "op")?;
    match op {
        "version" => Ok(json!({
            "abi": ABI_VERSION,
            "engine": "vodozemac",
            "version": vodozemac::VERSION,
        })),
        "create_account" => create_account(request),
        "prepare_prekeys" => prepare_prekeys(request),
        "mark_keys_published" => mark_keys_published(request),
        "forget_previous_fallback" => forget_previous_fallback(request),
        "create_outbound_session" => create_outbound_session(request),
        "create_inbound_session" => create_inbound_session(request),
        "encrypt" => encrypt(request),
        "decrypt" => decrypt(request),
        _ => Err("unknown_operation"),
    }
}

fn create_account(request: &Value) -> Result<Value, &'static str> {
    let count = request
        .get("one_time_key_count")
        .and_then(Value::as_u64)
        .unwrap_or(8) as usize;
    if count == 0 || count > MAX_ONE_TIME_KEYS {
        return Err("invalid_one_time_key_count");
    }

    let mut account = Account::new();
    account.generate_one_time_keys(count);
    let one_time_keys = serialize_public_keys(account.one_time_keys().values())?;

    Ok(json!({
        "account_pickle": serialize_account(&account)?,
        "curve25519": serde_json::to_value(account.curve25519_key())
            .map_err(|_| "serialization_failed")?,
        "ed25519": serde_json::to_value(account.ed25519_key())
            .map_err(|_| "serialization_failed")?,
        "one_time_keys": one_time_keys,
    }))
}

fn prepare_prekeys(request: &Value) -> Result<Value, &'static str> {
    let mut account = parse_account(request)?;
    let target = request
        .get("target_one_time_key_count")
        .and_then(Value::as_u64)
        .ok_or("missing_target_one_time_key_count")? as usize;
    let upstream_max = account.max_number_of_one_time_keys();
    let allowed_max = upstream_max.min(MAX_ONE_TIME_KEYS);
    if target == 0 || target > allowed_max {
        return Err("invalid_one_time_key_target");
    }

    let stored = account.stored_one_time_key_count();
    if stored < target {
        account.generate_one_time_keys(target - stored);
    }
    if request
        .get("rotate_fallback")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        account.generate_fallback_key();
    }

    let one_time_keys = serialize_public_keys(account.one_time_keys().values())?;
    let fallback_keys = serialize_public_keys(account.fallback_key().values())?;

    Ok(json!({
        "account_pickle": serialize_account(&account)?,
        "curve25519": serde_json::to_value(account.curve25519_key())
            .map_err(|_| "serialization_failed")?,
        "ed25519": serde_json::to_value(account.ed25519_key())
            .map_err(|_| "serialization_failed")?,
        "one_time_keys": one_time_keys,
        "fallback_keys": fallback_keys,
        "stored_one_time_key_count": account.stored_one_time_key_count(),
        "max_one_time_key_count": upstream_max,
    }))
}

fn mark_keys_published(request: &Value) -> Result<Value, &'static str> {
    let mut account = parse_account(request)?;
    account.mark_keys_as_published();
    Ok(json!({"account_pickle": serialize_account(&account)?}))
}

fn forget_previous_fallback(request: &Value) -> Result<Value, &'static str> {
    let mut account = parse_account(request)?;
    let forgotten = account.forget_fallback_key();
    Ok(json!({
        "account_pickle": serialize_account(&account)?,
        "forgotten": forgotten,
    }))
}

fn create_outbound_session(request: &Value) -> Result<Value, &'static str> {
    let account = parse_account(request)?;
    let remote_identity = key_field(request, "remote_identity_key")?;
    let remote_one_time = key_field(request, "remote_one_time_key")?;
    let session = account
        .create_outbound_session(SessionConfig::version_1(), remote_identity, remote_one_time)
        .map_err(|_| "session_creation_failed")?;
    Ok(json!({
        "session_id": session.session_id(),
        "session_pickle": serialize_session(&session)?,
    }))
}

fn create_inbound_session(request: &Value) -> Result<Value, &'static str> {
    let mut account = parse_account(request)?;
    let remote_identity = key_field(request, "remote_identity_key")?;
    let message = message_field(request)?;
    let prekey = match message {
        OlmMessage::PreKey(value) => value,
        OlmMessage::Normal(_) => return Err("expected_prekey_message"),
    };

    let inbound = account
        .create_inbound_session(SessionConfig::version_1(), remote_identity, &prekey)
        .map_err(|_| "session_creation_failed")?;
    Ok(json!({
        "account_pickle": serialize_account(&account)?,
        "session_id": inbound.session.session_id(),
        "session_pickle": serialize_session(&inbound.session)?,
        "plaintext": vodozemac::base64_encode(inbound.plaintext),
    }))
}

fn encrypt(request: &Value) -> Result<Value, &'static str> {
    let mut session = parse_session(request)?;
    let plaintext = string_field(request, "plaintext")?;
    let plaintext = vodozemac::base64_decode(plaintext).map_err(|_| "invalid_plaintext")?;
    let message: OlmMessage = session
        .encrypt(&plaintext)
        .map_err(|_| "encryption_failed")?;
    Ok(json!({
        "session_id": session.session_id(),
        "session_pickle": serialize_session(&session)?,
        "message": serde_json::to_value(message).map_err(|_| "serialization_failed")?,
    }))
}

fn decrypt(request: &Value) -> Result<Value, &'static str> {
    let mut session = parse_session(request)?;
    let message = message_field(request)?;
    let plaintext = session.decrypt(&message).map_err(|_| "decryption_failed")?;
    Ok(json!({
        "session_id": session.session_id(),
        "session_pickle": serialize_session(&session)?,
        "plaintext": vodozemac::base64_encode(plaintext),
    }))
}

fn parse_account(request: &Value) -> Result<Account, &'static str> {
    let pickle = string_field(request, "account_pickle")?;
    let parsed =
        serde_json::from_str::<AccountPickle>(pickle).map_err(|_| "invalid_account_pickle")?;
    Ok(parsed.into())
}

fn parse_session(request: &Value) -> Result<Session, &'static str> {
    let pickle = string_field(request, "session_pickle")?;
    let parsed =
        serde_json::from_str::<SessionPickle>(pickle).map_err(|_| "invalid_session_pickle")?;
    Ok(Session::from_pickle(parsed))
}

fn serialize_account(account: &Account) -> Result<String, &'static str> {
    serde_json::to_string(&account.pickle()).map_err(|_| "serialization_failed")
}

fn serialize_session(session: &Session) -> Result<String, &'static str> {
    serde_json::to_string(&session.pickle()).map_err(|_| "serialization_failed")
}

fn serialize_public_keys<'a>(
    keys: impl Iterator<Item = &'a Curve25519PublicKey>,
) -> Result<Vec<Value>, &'static str> {
    keys.map(|key| serde_json::to_value(key).map_err(|_| "serialization_failed"))
        .collect()
}

fn message_field(request: &Value) -> Result<OlmMessage, &'static str> {
    let value = request.get("message").ok_or("missing_message")?.clone();
    serde_json::from_value(value).map_err(|_| "invalid_message")
}

fn key_field(request: &Value, name: &'static str) -> Result<Curve25519PublicKey, &'static str> {
    let value = request.get(name).ok_or("missing_key")?.clone();
    serde_json::from_value(value).map_err(|_| "invalid_key")
}

fn string_field<'a>(request: &'a Value, name: &'static str) -> Result<&'a str, &'static str> {
    request
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or("missing_field")
}

fn error_response(code: &'static str) -> Value {
    json!({"ok": false, "error": code})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_abi_round_trip_establishes_and_decrypts() {
        let bob = dispatch(&json!({"op":"create_account","one_time_key_count":1})).unwrap();
        let alice = dispatch(&json!({"op":"create_account","one_time_key_count":1})).unwrap();
        let bob_otk = bob["one_time_keys"][0].clone();

        let outbound = dispatch(&json!({
            "op":"create_outbound_session",
            "account_pickle":alice["account_pickle"],
            "remote_identity_key":bob["curve25519"],
            "remote_one_time_key":bob_otk,
        }))
        .unwrap();
        let encrypted = dispatch(&json!({
            "op":"encrypt",
            "session_pickle":outbound["session_pickle"],
            "plaintext":vodozemac::base64_encode(b"ffi-poc"),
        }))
        .unwrap();
        let inbound = dispatch(&json!({
            "op":"create_inbound_session",
            "account_pickle":bob["account_pickle"],
            "remote_identity_key":alice["curve25519"],
            "message":encrypted["message"],
        }))
        .unwrap();

        assert_eq!(inbound["session_id"], encrypted["session_id"]);
        assert_eq!(
            vodozemac::base64_decode(inbound["plaintext"].as_str().unwrap()).unwrap(),
            b"ffi-poc"
        );
    }

    #[test]
    fn prekey_inventory_replenishes_and_rotates_fallback() {
        let account = dispatch(&json!({"op":"create_account","one_time_key_count":1})).unwrap();
        let first = dispatch(&json!({
            "op":"prepare_prekeys",
            "account_pickle":account["account_pickle"],
            "target_one_time_key_count":4,
            "rotate_fallback":true,
        }))
        .unwrap();
        assert_eq!(first["stored_one_time_key_count"], 4);
        assert_eq!(first["one_time_keys"].as_array().unwrap().len(), 4);
        assert_eq!(first["fallback_keys"].as_array().unwrap().len(), 1);

        let published = dispatch(&json!({
            "op":"mark_keys_published",
            "account_pickle":first["account_pickle"],
        }))
        .unwrap();
        let second = dispatch(&json!({
            "op":"prepare_prekeys",
            "account_pickle":published["account_pickle"],
            "target_one_time_key_count":4,
            "rotate_fallback":false,
        }))
        .unwrap();
        assert_eq!(second["one_time_keys"].as_array().unwrap().len(), 0);
        assert_eq!(second["fallback_keys"].as_array().unwrap().len(), 0);
    }
}
