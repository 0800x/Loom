//! Stateless byte ABI: every successful operation returns the next sealed state.
//! If validation fails, no state is returned. The caller atomically stores that
//! state with the exact outbox bytes before any network request.
use crate::*;
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use zeroize::Zeroize;
#[derive(Deserialize)]
struct Request {
    operation: String,
    device: Vec<u8>,
    key: Vec<u8>,
    generation: u64,
    #[serde(default)]
    state: Vec<u8>,
    #[serde(default)]
    group: Vec<u8>,
    #[serde(default)]
    bytes: Vec<u8>,
    #[serde(default)]
    pins: Vec<DevicePin>,
    #[serde(default)]
    packages: Vec<(Vec<u8>, DevicePin)>,
    #[serde(default)]
    remove: Vec<Vec<u8>>,
    #[serde(default)]
    epoch: u64,
}
impl Drop for Request {
    fn drop(&mut self) {
        self.key.zeroize();
        self.bytes.zeroize();
    }
}
#[repr(C)]
pub struct Output {
    pub data: *mut u8,
    pub len: usize,
}
fn dispatch(input: &[u8]) -> Result<Value> {
    let r: Request = serde_json::from_slice(input).map_err(|_| "Invalid MLS request".to_owned())?;
    let key: [u8; 32] = r
        .key
        .as_slice()
        .try_into()
        .map_err(|_| "Invalid sealing key")?;
    let key = Zeroizing::new(key);
    let engine = if r.operation == "new" {
        Engine::new(r.device.clone())?
    } else {
        Engine::restore(&r.state, &key, &r.device, r.generation)?
    };
    let result = match r.operation.as_str() {
        "new" => json!({"pin":engine.pin()}),
        "pin" => json!({"pin":engine.pin()}),
        "rotate" => serde_json::to_value(engine.rotate(&r.group)?).map_err(error)?,
        "keyPackage" => json!({"bytes":engine.key_package()?,"pin":engine.pin()}),
        "create" => {
            engine.create(&r.group)?;
            json!({"epoch":0})
        }
        "add" => serde_json::to_value(engine.add(&r.group, &r.packages)?).map_err(error)?,
        "remove" => serde_json::to_value(engine.remove(&r.group, &r.remove)?).map_err(error)?,
        "acceptPending" => json!({"epoch":engine.accept_pending(&r.group,&r.pins)?}),
        "join" => json!({"epoch":engine.join(&r.group,&r.bytes,&r.pins)?}),
        "exportCallKey" => {
            let mut bytes = engine.export_call_key(&r.group,&r.bytes,r.epoch)?;
            let output = json!({"bytes": bytes});
            bytes.zeroize();
            output
        }
        "encrypt" => {
            let (epoch, bytes) = engine.encrypt(&r.group, &r.bytes)?;
            json!({"epoch":epoch,"bytes":bytes})
        }
        "receive" => {
            serde_json::to_value(engine.receive(&r.group, &r.bytes, &r.pins)?).map_err(error)?
        }
        _ => return Err("Unsupported MLS operation".into()),
    };
    let generation = r.generation.checked_add(1).ok_or("Generation overflow")?;
    Ok(json!({"result":result,"generation":generation,"state":engine.seal(&key,generation)?}))
}
/// # Safety
/// data must point to len readable bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn loom_mls_request(data: *const u8, len: usize) -> *mut Output {
    let mut result = catch_unwind(AssertUnwindSafe(|| {
        if data.is_null() || len == 0 || len > 128 * 1024 * 1024 {
            return json!({"error":"Invalid MLS input"});
        }
        match dispatch(std::slice::from_raw_parts(data, len)) {
            Ok(value) => value,
            Err(_) => json!({"error":"MLS operation rejected"}),
        }
    }))
    .unwrap_or_else(|_| json!({"error":"MLS operation rejected"}));
    let bytes = serde_json::to_vec(&result)
        .unwrap_or_else(|_| b"{\"error\":\"MLS operation rejected\"}".to_vec())
        .into_boxed_slice();
    // Wipe the transient JSON byte array after serializing the ABI response.
    if let Some(values) = result.get_mut("result").and_then(|v| v.get_mut("bytes")).and_then(Value::as_array_mut) {
        for value in values.iter_mut() { std::ptr::write_volatile(value, json!(0)); }
    }
    let len = bytes.len();
    let data = Box::into_raw(bytes) as *mut u8;
    Box::into_raw(Box::new(Output { data, len }))
}
/// # Safety
/// output must be an unreleased pointer returned by loom_mls_request.
#[no_mangle]
pub unsafe extern "C" fn loom_mls_release(output: *mut Output) {
    if output.is_null() {
        return;
    }
    let output = Box::from_raw(output);
    let mut bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(output.data, output.len));
    bytes.zeroize();
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stateless_operation_advances_generation_and_rejects_tampered_state() {
        let request = json!({"operation":"new","device":[97],"key":vec![3;32],"generation":0});
        let created = dispatch(&serde_json::to_vec(&request).unwrap()).unwrap();
        let mut next = json!({"operation":"keyPackage","device":[97],"key":vec![3;32],"generation":1,"state":created["state"]});
        assert_eq!(
            dispatch(&serde_json::to_vec(&next).unwrap()).unwrap()["generation"],
            2
        );
        next["generation"] = json!(0);
        assert!(dispatch(&serde_json::to_vec(&next).unwrap()).is_err());
        next["generation"] = json!(1);
        next["state"][15] = json!(255);
        assert!(dispatch(&serde_json::to_vec(&next).unwrap()).is_err());
    }
    #[test]
    fn malformed_ffi_returns_an_error_and_can_be_released() {
        unsafe {
            let out = loom_mls_request(std::ptr::null(), 0);
            assert!(!out.is_null());
            let bytes = std::slice::from_raw_parts((*out).data, (*out).len);
            assert!(serde_json::from_slice::<Value>(bytes)
                .unwrap()
                .get("error")
                .is_some());
            loom_mls_release(out);
        }
    }
}
