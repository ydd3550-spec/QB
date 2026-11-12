//! قراءة متسامحة للحقول: نص أو رقم أو مصفوفة، وأي شي غلط يصير None.
use serde_json::Value;

pub fn str_field(v: &Value, key: &str) -> Option<String> {
    match v.get(key)? {
        Value::String(s) => {
            let t = s.trim();
            if t.is_empty() { None } else { Some(t.to_string()) }
        }
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

pub fn u32_field(v: &Value, key: &str) -> Option<u32> {
    match v.get(key)? {
        Value::Number(n) => n.as_u64().map(|x| x.min(u32::MAX as u64) as u32),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn str_list(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|x| match x {
                Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .collect(),
        Some(Value::String(s)) if !s.trim().is_empty() => vec![s.trim().to_string()],
        _ => vec![],
    }
}
