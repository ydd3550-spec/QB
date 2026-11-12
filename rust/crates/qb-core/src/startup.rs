//! حماية تشغيل النواة: أي panic يرجع خطأ فيه المرحلة ومكان السطر (file:line:col)،
//! وفحص الساعة قبل أي شي لأن moka وtokio يعتمدون على Instant::now.
use qb_model::CoreError;
use std::sync::{Mutex, Once};

static HOOK: Once = Once::new();
static LAST_LOCATION: Mutex<Option<String>> = Mutex::new(None);

/// يركّب hook يحفظ مكان آخر panic (مرة وحدة، ويخلي الـ hook القديم يشتغل بعده)
pub fn install_panic_hook() {
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if let Some(loc) = info.location() {
                if let Ok(mut l) = LAST_LOCATION.lock() {
                    *l = Some(format!("{}:{}:{}", loc.file(), loc.line(), loc.column()));
                }
            }
            previous(info);
        }));
    });
}

fn take_location() -> Option<String> {
    LAST_LOCATION.lock().ok().and_then(|mut l| l.take())
}

/// يشغّل خطوة من التشغيل؛ لو صار panic يرجع خطأ: "<stage>: panic at <file:line:col>: <msg>"
pub fn stage<T>(name: &str, f: impl FnOnce() -> Result<T, CoreError>) -> Result<T, CoreError> {
    install_panic_hook();
    let _ = take_location();
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(p) => {
            let at = take_location().unwrap_or_else(|| "unknown location".into());
            Err(CoreError::storage(format!("{name}: panic at {at}: {}", qb_net::panic_text(&*p))))
        }
    }
}

/// يتأكد إن ساعة النظام (Instant/SystemTime) شغّالة قبل ما نبني الكاش
pub fn check_clock() -> Result<(), CoreError> {
    stage("clock", || {
        let a = std::time::Instant::now();
        let _ = std::time::SystemTime::now();
        let _ = a.elapsed();
        Ok(())
    })
}
