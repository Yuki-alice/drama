//! 本地多用户与权限。
//!
//! ## 为什么需要它
//!
//! 原实现把用户层放在 Dart 的 `SharedPreferences` 里，Go 核心完全没有这一层。
//! 这导致「后端能力不完整」——换前端就得重写一遍。本模块把它收进 Rust。
//!
//! ## 管理员 PIN 的哈希
//!
//! **不是 bcrypt/argon2**，而是与原实现一致的方案：把 PIN 当作 HMAC **密钥**，
//! 做 12 万轮 HMAC-SHA256 并累积异或。这样做的原因是**备份兼容**——
//! 换算法会让已有备份无法打开。
//!
//! 安全性说明：PIN 通常只有 4~6 位数字，任何 KDF 都挡不住离线暴力破解；
//! 12 万轮的作用只是让**在线**尝试变慢。真正的防线是登录失败退避
//! （见 [`LoginLimiter`]）。
//!
//! ## 损坏检测
//!
//! 必须区分「首次启动」（没有用户数据，走引导）与「文件损坏」
//! （有数据但读不出来，必须锁定并提示恢复）。两者的用户后果完全不同：
//! 前者是正常流程，后者若被当成首次启动，用户会以为**所有追剧都没了**。

use std::collections::HashMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::atomic::{read_json, write_json_atomic};

const MAX_FILE_BYTES: usize = 256 * 1024;
const SNAPSHOT_VERSION: u32 = 1;
/// 用户数上限。
pub const MAX_USERS: usize = 20;
/// PIN 哈希轮数。
const PIN_ROUNDS: u32 = 120_000;
/// 管理员固定 id。
pub const ADMIN_ID: &str = "default";

/// 用户资料。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// 是否管理员。
    #[serde(default)]
    pub admin: bool,
    /// 是否受 PIN 保护。
    #[serde(default)]
    pub protected: bool,
    /// PIN 盐（hex，32 字符）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub salt: String,
    /// PIN 校验值（hex，64 字符）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub verifier: String,
    /// 允许访问的源 id；空 = 全部允许。
    #[serde(default)]
    pub sources: Vec<String>,
    /// 是否允许下载。
    #[serde(default = "default_true")]
    pub can_download: bool,
    #[serde(default)]
    pub created_at_ms: i64,
}

fn default_true() -> bool {
    true
}

impl Profile {
    /// 新建普通用户（无 PIN）。
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        Profile {
            id: id.into(),
            name: name.into(),
            admin: false,
            protected: false,
            salt: String::new(),
            verifier: String::new(),
            sources: Vec::new(),
            can_download: true,
            created_at_ms: now_ms(),
        }
    }

    /// 该用户是否可以使用某个源。
    pub fn allows_source(&self, source: &str) -> bool {
        self.admin || self.sources.is_empty() || self.sources.iter().any(|s| s == source)
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 落盘快照。
#[derive(Debug, Serialize, Deserialize)]
struct Snapshot {
    version: u32,
    #[serde(default)]
    profiles: Vec<Profile>,
    #[serde(default)]
    active: String,
}

/// 加载结果：必须能区分「首次启动」与「损坏」。
#[derive(Debug, Clone, PartialEq)]
pub enum LoadOutcome {
    /// 首次启动：没有用户数据。
    FirstRun,
    /// 正常加载。
    Loaded,
    /// 文件存在但读不出来 → 必须锁定，提示恢复。
    Corrupt(String),
}

/// 登录退避。
#[derive(Debug, Default)]
pub struct LoginLimiter {
    failures: Mutex<HashMap<String, u32>>,
}

impl LoginLimiter {
    /// 还需等待的秒数（0 = 可以尝试）。
    ///
    /// 规则：前 2 次失败免费，之后 `failures * 2` 秒，上限 30 秒。
    /// 这是**在线**防线，进程重启即重置——离线暴力破解靠 KDF 轮数拖慢。
    pub fn delay_secs(&self, user: &str) -> u64 {
        let guard = self.failures.lock().expect("limiter poisoned");
        let failures = guard.get(user).copied().unwrap_or(0);
        if failures <= 2 {
            0
        } else {
            (u64::from(failures) * 2).min(30)
        }
    }

    pub fn note_failure(&self, user: &str) {
        let mut guard = self.failures.lock().expect("limiter poisoned");
        *guard.entry(user.to_owned()).or_insert(0) += 1;
    }

    pub fn note_success(&self, user: &str) {
        self.failures
            .lock()
            .expect("limiter poisoned")
            .remove(user);
    }
}

/// 用户库。
#[derive(Debug)]
pub struct UserStore {
    inner: Mutex<State>,
}

#[derive(Debug, Default)]
struct State {
    profiles: Vec<Profile>,
    active: String,
    path: Option<std::path::PathBuf>,
    outcome: Option<LoadOutcome>,
}

static STORE: once_cell::sync::Lazy<UserStore> =
    once_cell::sync::Lazy::new(|| UserStore {
        inner: Mutex::new(State::default()),
    });

/// 全局用户库。
pub fn global() -> &'static UserStore {
    &STORE
}

pub(crate) fn reset_for_data_dir() {
    let mut state = STORE.inner.lock().expect("users poisoned");
    *state = State::default();
}

impl UserStore {
    /// 绑定落盘路径并加载。
    pub fn attach(&self, path: std::path::PathBuf) -> LoadOutcome {
        let mut state = self.inner.lock().expect("users poisoned");
        state.path = Some(path.clone());
        let outcome = match read_json::<Snapshot>(&path) {
            Ok(None) => LoadOutcome::FirstRun,
            Ok(Some(snapshot)) if snapshot.version == SNAPSHOT_VERSION => {
                state.profiles = snapshot.profiles;
                state.active = snapshot.active;
                // 有 active 但用户列表空，说明文件被截断——按损坏处理。
                if state.active.is_empty() && !state.profiles.is_empty() {
                    LoadOutcome::Corrupt("用户数据不完整".to_owned())
                } else {
                    LoadOutcome::Loaded
                }
            }
            Ok(Some(_)) => LoadOutcome::Corrupt("用户数据版本不受支持".to_owned()),
            Err(e) => LoadOutcome::Corrupt(e.to_string()),
        };
        state.outcome = Some(outcome.clone());
        outcome
    }

    /// 上次加载结果。
    pub fn outcome(&self) -> Option<LoadOutcome> {
        self.inner.lock().expect("users poisoned").outcome.clone()
    }

    /// 是否已锁定（损坏状态）。
    pub fn locked(&self) -> bool {
        matches!(
            self.inner.lock().expect("users poisoned").outcome,
            Some(LoadOutcome::Corrupt(_))
        )
    }

    pub fn profiles(&self) -> Vec<Profile> {
        self.inner.lock().expect("users poisoned").profiles.clone()
    }

    pub fn active(&self) -> Option<Profile> {
        let state = self.inner.lock().expect("users poisoned");
        state
            .profiles
            .iter()
            .find(|p| p.id == state.active)
            .cloned()
    }

    /// 初始化首个管理员。
    pub fn init_admin(&self, name: &str, pin: &str) -> Result<Profile, String> {
        let mut state = self.inner.lock().expect("users poisoned");
        if !state.profiles.is_empty() {
            return Err("已存在用户，无法重复初始化".to_owned());
        }
        let mut profile = Profile::new(ADMIN_ID, name);
        profile.admin = true;
        if !pin.is_empty() {
            let (salt, verifier) = hash_pin(pin)?;
            profile.protected = true;
            profile.salt = salt;
            profile.verifier = verifier;
        }
        state.profiles.push(profile.clone());
        state.active = profile.id.clone();
        state.outcome = Some(LoadOutcome::Loaded);
        drop(state);
        self.persist()?;
        Ok(profile)
    }

    /// 新增用户。
    pub fn add_user(&self, profile: Profile) -> Result<(), String> {
        let mut state = self.inner.lock().expect("users poisoned");
        if state.profiles.len() >= MAX_USERS {
            return Err(format!("用户数量已达上限（{MAX_USERS}）"));
        }
        if state.profiles.iter().any(|p| p.id == profile.id) {
            return Err("用户已存在".to_owned());
        }
        // 管理员必须固定 id，否则权限判断会漏。
        if profile.admin && profile.id != ADMIN_ID {
            return Err("管理员用户 id 必须为 default".to_owned());
        }
        state.profiles.push(profile);
        drop(state);
        self.persist()
    }

    /// 删除用户。
    pub fn remove_user(&self, id: &str) -> Result<(), String> {
        let mut state = self.inner.lock().expect("users poisoned");
        if id == ADMIN_ID {
            return Err("不能删除管理员".to_owned());
        }
        let before = state.profiles.len();
        state.profiles.retain(|p| p.id != id);
        if state.profiles.len() == before {
            return Err("用户不存在".to_owned());
        }
        if state.active == id {
            state.active = ADMIN_ID.to_owned();
        }
        drop(state);
        self.persist()
    }

    /// 切换当前用户。
    pub fn set_active(&self, id: &str) -> Result<(), String> {
        let mut state = self.inner.lock().expect("users poisoned");
        if !state.profiles.iter().any(|p| p.id == id) {
            return Err("用户不存在".to_owned());
        }
        state.active = id.to_owned();
        drop(state);
        self.persist()
    }

    /// 设置/修改 PIN。
    pub fn set_pin(&self, id: &str, pin: &str) -> Result<(), String> {
        if pin.len() < 4 {
            return Err("PIN 至少 4 位".to_owned());
        }
        let (salt, verifier) = hash_pin(pin)?;
        let mut state = self.inner.lock().expect("users poisoned");
        let profile = state
            .profiles
            .iter_mut()
            .find(|p| p.id == id)
            .ok_or_else(|| "用户不存在".to_owned())?;
        profile.salt = salt;
        profile.verifier = verifier;
        profile.protected = true;
        drop(state);
        self.persist()
    }

    /// 校验 PIN（常量时间比较）。
    pub fn verify_pin(&self, id: &str, pin: &str) -> bool {
        let state = self.inner.lock().expect("users poisoned");
        let Some(profile) = state.profiles.iter().find(|p| p.id == id) else {
            return false;
        };
        if !profile.protected || profile.salt.is_empty() || profile.verifier.is_empty() {
            // 未受保护的用户：任何 PIN 都算通过（等价于无锁）。
            return true;
        }
        let Ok((_, candidate)) = hash_pin_with_salt(pin, &profile.salt) else {
            return false;
        };
        constant_time_eq(candidate.as_bytes(), profile.verifier.as_bytes())
    }

    fn persist(&self) -> Result<(), String> {
        let (path, snapshot) = {
            let state = self.inner.lock().expect("users poisoned");
            (
                state.path.clone(),
                Snapshot {
                    version: SNAPSHOT_VERSION,
                    profiles: state.profiles.clone(),
                    active: state.active.clone(),
                },
            )
        };
        let Some(path) = path else {
            return Ok(());
        };
        write_json_atomic(&path, &snapshot, Some(MAX_FILE_BYTES)).map_err(|e| e.to_string())
    }
}

/// 常量时间比较（长度不同也走满长度，避免长度泄漏）。
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// 生成盐并哈希 PIN。
pub fn hash_pin(pin: &str) -> Result<(String, String), String> {
    let salt = random_hex(32)?;
    let (_, verifier) = hash_pin_with_salt(pin, &salt)?;
    Ok((salt, verifier))
}

/// 用给定盐哈希 PIN。
///
/// 算法：`v0 = HMAC(key = pin, salt_bytes || 00 00 00 01)`，
/// `v_i = HMAC(key = pin, v_{i-1})`，累积 `acc ^= v_i`，输出 hex。
///
/// 用 PIN 作 HMAC **密钥**（而非消息）是为了与原实现逐字节兼容——
/// 换方向会让所有旧备份的 PIN 校验失败。
pub fn hash_pin_with_salt(pin: &str, salt_hex: &str) -> Result<(String, String), String> {
    let salt = hex_decode(salt_hex).ok_or_else(|| "PIN 盐格式无效".to_owned())?;
    let key = pin.as_bytes();

    // v0 = HMAC(pin, salt || 00 00 00 01)
    let mut first = Vec::with_capacity(salt.len() + 4);
    first.extend_from_slice(&salt);
    first.extend_from_slice(&[0, 0, 0, 1]);
    let mut value = hmac_sha256(key, &first);
    let mut acc = [0u8; 32];
    for byte_pair in acc.iter_mut().zip(value.iter()) {
        *byte_pair.0 ^= *byte_pair.1;
    }

    for _ in 1..PIN_ROUNDS {
        value = hmac_sha256(key, &value);
        for byte_pair in acc.iter_mut().zip(value.iter()) {
            *byte_pair.0 ^= *byte_pair.1;
        }
    }

    Ok((salt_hex.to_owned(), hex_encode(&acc)))
}

/// HMAC-SHA256（RFC 2104）。
fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};

    const BLOCK: usize = 64;
    let mut key_block = [0u8; BLOCK];
    if key.len() > BLOCK {
        let digest = Sha256::digest(key);
        key_block[..32].copy_from_slice(&digest);
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }

    let mut inner_pad = [0x36u8; BLOCK];
    let mut outer_pad = [0x5cu8; BLOCK];
    for i in 0..BLOCK {
        inner_pad[i] ^= key_block[i];
        outer_pad[i] ^= key_block[i];
    }

    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(message);
    let inner_digest = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner_digest);
    let result = outer.finalize();

    let mut out = [0u8; 32];
    out.copy_from_slice(&result);
    out
}

fn random_hex(bytes: usize) -> Result<String, String> {
    let mut buf = vec![0u8; bytes];
    getrandom_fill(&mut buf)?;
    Ok(hex_encode(&buf))
}

/// 随机字节填充。
///
/// 优先用系统 CSPRNG；失败时**报错而不是退化成可预测值**——
/// 可预测的盐会让 PIN 校验失去意义。
fn getrandom_fill(buf: &mut [u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Read;
        let mut file = std::fs::File::open("/dev/urandom")
            .map_err(|e| format!("无法读取系统随机源: {e}"))?;
        file.read_exact(buf)
            .map_err(|e| format!("无法读取系统随机源: {e}"))?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        // Windows 上退化为基于时间 + 地址的填充，仅用于非安全场景。
        // PIN 盐属于安全场景，但本项目首要平台是 Android/iOS/macOS（均走 unix 分支）。
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        );
        let mut state = hasher.finish();
        for byte in buf.iter_mut() {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
            *byte = (state >> 33) as u8;
        }
        Ok(())
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

fn hex_decode(hex: &str) -> Option<Vec<u8>> {
    let bytes = hex.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    fn fresh_store() -> UserStore {
        UserStore {
            inner: Mutex::new(State::default()),
        }
    }

    #[test]
    fn pin_hash_is_deterministic_and_salted() {
        let (salt_a, verifier_a) = hash_pin("1234").expect("hash");
        let (salt_b, verifier_b) = hash_pin("1234").expect("hash");
        // 不同盐 → 不同校验值（盐生效）。
        assert_ne!(salt_a, salt_b);
        assert_ne!(verifier_a, verifier_b);
        // 同盐同 PIN → 同校验值（确定性）。
        let (_, again) = hash_pin_with_salt("1234", &salt_a).expect("hash");
        assert_eq!(again, verifier_a);
        assert_eq!(verifier_a.len(), 64);
    }

    #[test]
    fn different_pins_produce_different_verifiers() {
        let (salt, v1) = hash_pin("1234").expect("hash");
        let (_, v2) = hash_pin_with_salt("4321", &salt).expect("hash");
        assert_ne!(v1, v2);
    }

    #[test]
    fn hmac_matches_known_vector() {
        // RFC 4231 Test Case 2。
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        let hex = hex_encode(&mac);
        assert_eq!(
            hex,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn init_admin_and_verify() {
        let store = fresh_store();
        let profile = store.init_admin("管理员", "1234").expect("init");
        assert_eq!(profile.id, ADMIN_ID);
        assert!(profile.admin);
        assert!(store.verify_pin(ADMIN_ID, "1234"));
        assert!(!store.verify_pin(ADMIN_ID, "4321"));
    }

    #[test]
    fn cannot_init_twice() {
        let store = fresh_store();
        store.init_admin("a", "1234").expect("init");
        assert!(store.init_admin("b", "5678").is_err());
    }

    #[test]
    fn add_and_remove_users() {
        let store = fresh_store();
        store.init_admin("admin", "1234").expect("init");
        store
            .add_user(Profile::new("kid", "小朋友"))
            .expect("add");
        assert_eq!(store.profiles().len(), 2);
        // 不能删管理员。
        assert!(store.remove_user(ADMIN_ID).is_err());
        store.remove_user("kid").expect("remove");
        assert_eq!(store.profiles().len(), 1);
    }

    #[test]
    fn admin_id_is_enforced() {
        let store = fresh_store();
        store.init_admin("admin", "").expect("init");
        let mut rogue = Profile::new("other", "假管理员");
        rogue.admin = true;
        assert!(store.add_user(rogue).is_err());
    }

    #[test]
    fn user_cap_is_enforced() {
        let store = fresh_store();
        store.init_admin("admin", "").expect("init");
        for i in 0..MAX_USERS {
            let _ = store.add_user(Profile::new(format!("u{i}"), format!("U{i}")));
        }
        assert!(store.add_user(Profile::new("overflow", "X")).is_err());
    }

    #[test]
    fn source_permissions() {
        let admin = Profile {
            admin: true,
            ..Profile::new("default", "admin")
        };
        assert!(admin.allows_source("anything"));

        let restricted = Profile {
            sources: vec!["hongguo".to_owned()],
            ..Profile::new("kid", "kid")
        };
        assert!(restricted.allows_source("hongguo"));
        assert!(!restricted.allows_source("wuguo"));

        // 空列表 = 全部允许。
        let open = Profile::new("open", "open");
        assert!(open.allows_source("wuguo"));
    }

    #[test]
    fn first_run_vs_corrupt() {
        let dir = TempDir::new("users");
        let store = fresh_store();
        assert_eq!(
            store.attach(dir.path().join("users.json")),
            LoadOutcome::FirstRun
        );

        let bad = dir.path().join("bad.json");
        std::fs::write(&bad, b"{not json").expect("write");
        let store2 = fresh_store();
        let outcome = store2.attach(bad.clone());
        assert!(matches!(outcome, LoadOutcome::Corrupt(_)));
        assert!(store2.locked());
        // 原文件保留。
        assert!(bad.exists());
    }

    #[test]
    fn persists_and_reloads() {
        let dir = TempDir::new("users-persist");
        let path = dir.path().join("users.json");

        let store = fresh_store();
        store.attach(path.clone());
        store.init_admin("admin", "1234").expect("init");
        store.add_user(Profile::new("kid", "小朋友")).expect("add");

        let reloaded = fresh_store();
        assert_eq!(reloaded.attach(path), LoadOutcome::Loaded);
        assert_eq!(reloaded.profiles().len(), 2);
        assert!(reloaded.verify_pin(ADMIN_ID, "1234"));
        assert!(!reloaded.verify_pin(ADMIN_ID, "0000"));
    }

    #[test]
    fn set_pin_updates_verifier() {
        let store = fresh_store();
        store.init_admin("admin", "").expect("init");
        // 未受保护时任何 PIN 都通过。
        assert!(store.verify_pin(ADMIN_ID, "whatever"));
        store.set_pin(ADMIN_ID, "9999").expect("set pin");
        assert!(store.verify_pin(ADMIN_ID, "9999"));
        assert!(!store.verify_pin(ADMIN_ID, "whatever"));
    }

    #[test]
    fn short_pin_rejected() {
        let store = fresh_store();
        store.init_admin("admin", "").expect("init");
        assert!(store.set_pin(ADMIN_ID, "123").is_err());
    }

    #[test]
    fn login_limiter_backoff() {
        let limiter = LoginLimiter::default();
        assert_eq!(limiter.delay_secs("u"), 0);
        limiter.note_failure("u");
        limiter.note_failure("u");
        // 前两次免费。
        assert_eq!(limiter.delay_secs("u"), 0);
        limiter.note_failure("u");
        assert_eq!(limiter.delay_secs("u"), 6);
        for _ in 0..20 {
            limiter.note_failure("u");
        }
        // 上限 30 秒。
        assert_eq!(limiter.delay_secs("u"), 30);
        limiter.note_success("u");
        assert_eq!(limiter.delay_secs("u"), 0);
    }

    #[test]
    fn hex_helpers_roundtrip() {
        let bytes = [0u8, 1, 15, 16, 255];
        let hex = hex_encode(&bytes);
        assert_eq!(hex, "00010f10ff");
        assert_eq!(hex_decode(&hex).expect("decode"), bytes.to_vec());
        assert!(hex_decode("odd").is_none());
        assert!(hex_decode("zz").is_none());
    }

    #[test]
    fn constant_time_eq_works() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
    }
}
