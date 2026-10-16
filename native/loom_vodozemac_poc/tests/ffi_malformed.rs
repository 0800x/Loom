use loom_vodozemac_poc as _; // Link the crate that owns the exported C ABI.
use serde_json::Value;
use std::ffi::{c_char, CStr};

unsafe extern "C" {
    fn loom_vodozemac_poc_call(input: *const u8, input_len: usize) -> *mut c_char;
    fn loom_vodozemac_poc_free(value: *mut c_char);
}

fn invoke(bytes: &[u8]) -> Option<Value> {
    let pointer = unsafe { loom_vodozemac_poc_call(bytes.as_ptr(), bytes.len()) };
    if pointer.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned();
    unsafe { loom_vodozemac_poc_free(pointer) };
    serde_json::from_str(&text).ok()
}

#[test]
fn malformed_corpus_returns_structured_errors_without_crossing_ffi_with_a_panic() {
    let mut corpus: Vec<Vec<u8>> = vec![
        Vec::new(),
        b"{".to_vec(),
        b"null".to_vec(),
        b"[]".to_vec(),
        b"{}".to_vec(),
        b"{\"op\":1}".to_vec(),
        b"{\"op\":\"unknown\"}".to_vec(),
        b"{\"op\":\"decrypt\"}".to_vec(),
        vec![0xff, 0xfe, 0xfd],
        vec![0; 4096],
        vec![b'['; 4096],
    ];

    for byte in 0u8..=255 {
        corpus.push(vec![byte]);
        corpus.push(vec![byte; 32]);
    }

    for input in corpus {
        let response = invoke(&input).expect("FFI must return a JSON response");
        assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
        let code = response
            .get("error")
            .and_then(Value::as_str)
            .expect("error response must expose a bounded error code");
        assert!(!code.is_empty());
        assert!(code.len() <= 64);
        assert!(code
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'));
    }
}

#[test]
fn oversized_input_is_rejected_before_json_parsing() {
    let input = vec![b'a'; 4 * 1024 * 1024 + 1];
    let response = invoke(&input).expect("FFI must return a JSON response");
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"], "invalid_request");
}
