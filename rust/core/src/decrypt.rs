//! MP4 CENC 解密与 moov 改写（播放交付面）。
//!
//! 网关对加密 MP4 不做透传：首读时解析 moov 建样本表，重写 moov
//!（去 `senc/saiz/saio/pssh`、`encv→avc1`、`enca→mp4a`），按 Range 解密样本后下发。
//! 播放器拿到的是干净 MP4，不依赖任何播放器端密钥配置。
//!
//! 范围：`cenc` 全样本 CTR（senc 内联 8 字节 IV、无子样本表）；
//! 遇到 `seig` 或非 cenc scheme 直接报错而不输出乱码。
//! 分片 MP4（`moof`）不在范围。

use aes::Aes128;
use aes::cipher::{BlockCipherEncrypt, KeyInit};

/// 样本定位（原始文件偏移）。
#[derive(Debug, Clone)]
pub struct Sample {
    pub start: u64,
    pub end: u64,
    /// 16 字节 CTR IV（8 字节 IV 高位补零）。
    pub iv: [u8; 16],
}

/// 改写后的电影结构。
#[derive(Debug)]
pub struct MoviePlan {
    /// moov 在原文件中的起止。
    pub moov_start: u64,
    pub moov_end: u64,
    /// 改写后的 moov 字节。
    pub new_moov: Vec<u8>,
    /// 新老 moov 长度差（moov 之后的内容偏移量）。
    pub delta: i64,
    /// 加密样本表（按 start 排序）。
    pub samples: Vec<Sample>,
}

/// 未终定的改写中间态（stco 尚未偏移，avcC 尚未植入）。
#[derive(Debug)]
pub struct RawPlan {
    pub moov_start: u64,
    pub moov_end: u64,
    pub old_moov_size: u64,
    pub new_moov: Vec<u8>,
    pub samples: Vec<Sample>,
    /// 首个视频加密样本的原文件区间（用于取 SPS/PPS 合成 avcC）。
    pub first_video: Option<(u64, u64)>,
    /// 视频轨还原为 avc1 但缺少 avcC（需合成；已有 hvcC/avcC 时为 false）。
    pub needs_avcc: bool,
}

#[derive(Debug)]
pub enum DecryptError {
    Unsupported(String),
    Truncated,
}

impl std::fmt::Display for DecryptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecryptError::Unsupported(m) => write!(f, "unsupported mp4: {m}"),
            DecryptError::Truncated => write!(f, "moov truncated"),
        }
    }
}

#[derive(Debug)]
struct BoxInfo {
    typ: [u8; 4],
    start: u64,
    header_len: u64,
    size: u64,
}

fn read_u32(data: &[u8], off: usize) -> Option<u32> {
    data.get(off..off + 4)
        .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

fn read_u64(data: &[u8], off: usize) -> Option<u64> {
    data.get(off..off + 8)
        .map(|b| u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
}

/// 解析一层子 box。
fn children(
    data: &[u8],
    base: u64,
    payload: std::ops::Range<usize>,
) -> Result<Vec<BoxInfo>, DecryptError> {
    let mut out = Vec::new();
    let mut off = payload.start;
    while off + 8 <= payload.end {
        let size32 = read_u32(data, off).ok_or(DecryptError::Truncated)?;
        let typ: [u8; 4] = data[off + 4..off + 8]
            .try_into()
            .map_err(|_| DecryptError::Truncated)?;
        let (size, header_len) = if size32 == 1 {
            let big = read_u64(data, off + 8).ok_or(DecryptError::Truncated)?;
            (big, 16)
        } else if size32 == 0 {
            (payload.end as u64 - base - off as u64, 8)
        } else {
            (size32 as u64, 8)
        };
        if size < header_len || off as u64 + size > payload.end as u64 {
            return Err(DecryptError::Truncated);
        }
        out.push(BoxInfo {
            typ,
            start: base + off as u64,
            header_len,
            size,
        });
        off += size as usize;
    }
    Ok(out)
}

fn find<'a>(boxes: &'a [BoxInfo], typ: &[u8; 4]) -> Option<&'a BoxInfo> {
    boxes.iter().find(|b| b.typ == *typ)
}

fn box_bytes<'a>(data: &'a [u8], base: u64, b: &BoxInfo) -> Result<&'a [u8], DecryptError> {
    let s = (b.start - base) as usize;
    data.get(s..s + b.size as usize)
        .ok_or(DecryptError::Truncated)
}

fn payload_range(
    data: &[u8],
    base: u64,
    b: &BoxInfo,
) -> Result<std::ops::Range<usize>, DecryptError> {
    let s = (b.start - base) as usize + b.header_len as usize;
    let e = (b.start - base) as usize + b.size as usize;
    if e > data.len() || s > e {
        return Err(DecryptError::Truncated);
    }
    Ok(s..e)
}

fn wrap_box(typ: [u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 8);
    out.extend_from_slice(&((payload.len() + 8) as u32).to_be_bytes());
    out.extend_from_slice(&typ);
    out.extend_from_slice(payload);
    out
}

/// 从 front（含 moov）构建改写中间态。`front_base` 为 front 在文件中的起始偏移。
/// stco 偏移与 avcC 植入在 [`finalize_plan`] 做。
pub fn analyze_moov(
    front: &[u8],
    front_base: u64,
    _key: &[u8; 16],
) -> Result<RawPlan, DecryptError> {
    // 顶层宽容扫描：只找 moov（mdat 等大 box 可能延伸出缓冲，不报错）。
    let mut moov_box: Option<BoxInfo> = None;
    let mut off = 0usize;
    while off + 8 <= front.len() {
        let size32 = read_u32(front, off).ok_or(DecryptError::Truncated)?;
        let typ: [u8; 4] = front[off + 4..off + 8]
            .try_into()
            .map_err(|_| DecryptError::Truncated)?;
        let (size, header_len) = if size32 == 1 {
            (read_u64(front, off + 8).ok_or(DecryptError::Truncated)?, 16)
        } else if size32 == 0 {
            (front.len() as u64 - off as u64, 8)
        } else {
            (size32 as u64, 8)
        };
        if size < header_len || size > (u32::MAX as u64) * 16 {
            return Err(DecryptError::Truncated);
        }
        if typ == *b"moov" {
            let end = off as u64 + size;
            if end > front.len() as u64 {
                return Err(DecryptError::Unsupported("moov beyond front".to_owned()));
            }
            moov_box = Some(BoxInfo {
                typ,
                start: front_base + off as u64,
                header_len,
                size,
            });
            break;
        }
        off += size as usize;
    }
    let moov = moov_box.ok_or_else(|| DecryptError::Unsupported("moov not in front".to_owned()))?;
    let moov_start = moov.start;
    let moov_end = moov.start + moov.size;
    let moov_payload = payload_range(front, front_base, &moov)?;

    let mut new_moov_payload = Vec::new();
    let mut samples: Vec<Sample> = Vec::new();
    let mut first_video: Option<(u64, u64)> = None;
    let mut needs_avcc = false;
    for child in children(front, front_base, moov_payload)? {
        match &child.typ {
            b"pssh" => continue,
            b"trak" => {
                let rebuilt = rebuild_trak(front, front_base, &child, &mut samples)?;
                if first_video.is_none() {
                    first_video = rebuilt.first_video;
                }
                needs_avcc |= rebuilt.needs_avcc;
                new_moov_payload.extend_from_slice(&rebuilt.bytes);
            }
            _ => new_moov_payload.extend_from_slice(box_bytes(front, front_base, &child)?),
        }
    }
    let new_size = (new_moov_payload.len() + 8) as u64;
    let mut new_moov = Vec::with_capacity(new_moov_payload.len() + 8);
    new_moov.extend_from_slice(&(new_size as u32).to_be_bytes());
    new_moov.extend_from_slice(b"moov");
    new_moov.extend_from_slice(&new_moov_payload);
    samples.sort_by_key(|s| s.start);
    Ok(RawPlan {
        moov_start,
        moov_end,
        old_moov_size: moov.size,
        new_moov,
        samples,
        first_video,
        needs_avcc,
    })
}

/// 终定：植入 avcC（如有）→ 偏移 stco/co64 → 算 delta。
pub fn finalize_plan(mut raw: RawPlan, avcc: Option<Vec<u8>>) -> Result<MoviePlan, DecryptError> {
    if let Some(avcc) = avcc {
        insert_avcc(&mut raw.new_moov, &avcc)?;
    }
    let delta = raw.new_moov.len() as i64 - raw.old_moov_size as i64;
    shift_chunk_offsets(&mut raw.new_moov, raw.moov_end, delta)?;
    Ok(MoviePlan {
        moov_start: raw.moov_start,
        moov_end: raw.moov_end,
        new_moov: raw.new_moov,
        delta,
        samples: raw.samples,
    })
}

/// 在首个 avc1 条目内植入 avcC（视频固定头 86 字节之后），并回填路径上各级尺寸。
fn insert_avcc(new_moov: &mut Vec<u8>, avcc: &[u8]) -> Result<(), DecryptError> {
    // 路径 moov/trak/mdia/minf/stbl/stsd/entry(avc1)，记录各级 box 起始。
    let owned = new_moov.clone();
    let top = children(&owned, 0, 0..owned.len())?;
    let moov = find(&top, b"moov").ok_or(DecryptError::Truncated)?;
    let mut path: Vec<u64> = vec![moov.start];
    let mut cursor = payload_range(&owned, 0, moov)?;
    let mut entry_start: Option<u64> = None;
    'outer: for level in [b"trak", b"mdia", b"minf", b"stbl", b"stsd"] {
        let mut found = None;
        for b in children(&owned, 0, cursor)? {
            if b.typ == *level {
                found = Some(b);
                break;
            }
        }
        let found = found.ok_or(DecryptError::Truncated)?;
        path.push(found.start);
        cursor = payload_range(&owned, 0, &found)?;
        if level == b"stsd" {
            for e in children(&owned, 0, (cursor.start + 8)..cursor.end)? {
                if e.typ == *b"avc1" {
                    entry_start = Some(e.start);
                    path.push(e.start);
                    break 'outer;
                }
            }
            return Err(DecryptError::Unsupported("no avc1 entry".to_owned()));
        }
    }
    let entry_start = entry_start.ok_or(DecryptError::Truncated)?;
    let at = (entry_start + 86) as usize;
    let entry_len_off = entry_start as usize;
    let entry_len = read_u32(&owned, entry_len_off).ok_or(DecryptError::Truncated)? as usize;
    if entry_len < 86 + 8 || at > new_moov.len() {
        return Err(DecryptError::Unsupported("avc1 entry too small".to_owned()));
    }
    new_moov.splice(at..at, avcc.iter().copied());
    // 回填路径各级尺寸（均为 32 位；改写产物保证无 largesize）。
    for start in path {
        let off = start as usize;
        if owned[off..off + 4] == [0, 0, 0, 1] {
            return Err(DecryptError::Unsupported("largesize moov".to_owned()));
        }
        let size = read_u32(new_moov, off).ok_or(DecryptError::Truncated)? as usize;
        let new_size = (size + avcc.len()) as u32;
        new_moov[off..off + 4].copy_from_slice(&new_size.to_be_bytes());
    }
    Ok(())
}

/// 从解密后的首视频样本提取 SPS/PPS（AVCC 4 字节长度前缀）。
pub fn extract_sps_pps(sample: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let mut sps = None;
    let mut pps = None;
    let mut off = 0usize;
    let mut nal_count = 0;
    while off + 4 <= sample.len() && nal_count < 16 {
        let len = u32::from_be_bytes([
            sample[off],
            sample[off + 1],
            sample[off + 2],
            sample[off + 3],
        ]) as usize;
        if len == 0 || len > 4_000_000 || off + 4 + len > sample.len() {
            break;
        }
        let nal_type = sample[off + 4] & 0x1f;
        if nal_type == 7 && sps.is_none() {
            sps = Some(sample[off + 4..off + 4 + len].to_vec());
        } else if nal_type == 8 && pps.is_none() {
            pps = Some(sample[off + 4..off + 4 + len].to_vec());
        }
        if sps.is_some() && pps.is_some() {
            break;
        }
        off += 4 + len;
        nal_count += 1;
    }
    match (sps, pps) {
        (Some(s), Some(p)) if s.len() >= 4 => Some((s, p)),
        _ => None,
    }
}

/// 组装 avcC box（含头）。
pub fn build_avcc(sps: &[u8], pps: &[u8]) -> Option<Vec<u8>> {
    if sps.len() < 4 || sps.len() > 65535 || pps.is_empty() || pps.len() > 65535 {
        return None;
    }
    let mut payload = Vec::with_capacity(sps.len() + pps.len() + 11);
    payload.push(1);
    payload.push(sps[1]);
    payload.push(sps[2]);
    payload.push(sps[3]);
    payload.push(0xff);
    payload.push(0xe1);
    payload.extend_from_slice(&(sps.len() as u16).to_be_bytes());
    payload.extend_from_slice(sps);
    payload.push(1);
    payload.extend_from_slice(&(pps.len() as u16).to_be_bytes());
    payload.extend_from_slice(pps);
    Some(wrap_box(*b"avcC", &payload))
}

/// 保持兼容的老入口（无 avcC 合成；仅单测用）。
#[cfg(test)]
pub fn analyze_moov_test_only(
    front: &[u8],
    front_base: u64,
    _key: &[u8; 16],
) -> Result<MoviePlan, DecryptError> {
    let raw = analyze_moov(front, front_base, _key)?;
    finalize_plan(raw, None)
}

/// stco/co64 修正：指向 moov 之后内容的偏移跟随 delta。
fn shift_chunk_offsets(moov: &mut [u8], moov_end: u64, delta: i64) -> Result<(), DecryptError> {
    let len = moov.len();
    let owned = moov.to_vec();
    let top = children(&owned, 0, 0..len)?;
    let moov_box = find(&top, b"moov").ok_or(DecryptError::Truncated)?;
    let moov_payload = payload_range(&owned, 0, moov_box)?;
    for trak in children(&owned, 0, moov_payload)?
        .into_iter()
        .filter(|b| b.typ == *b"trak")
    {
        let trak_payload = payload_range(&owned, 0, &trak)?;
        for mdia in children(&owned, 0, trak_payload)?
            .into_iter()
            .filter(|b| b.typ == *b"mdia")
        {
            let mdia_payload = payload_range(&owned, 0, &mdia)?;
            for minf in children(&owned, 0, mdia_payload)?
                .into_iter()
                .filter(|b| b.typ == *b"minf")
            {
                let minf_payload = payload_range(&owned, 0, &minf)?;
                for stbl in children(&owned, 0, minf_payload)?
                    .into_iter()
                    .filter(|b| b.typ == *b"stbl")
                {
                    let stbl_payload = payload_range(&owned, 0, &stbl)?;
                    for entry in children(&owned, 0, stbl_payload)? {
                        match &entry.typ {
                            b"stco" => {
                                let base = entry.start as usize + 8 + 4;
                                let count =
                                    read_u32(&owned, base).ok_or(DecryptError::Truncated)? as usize;
                                for i in 0..count {
                                    let off = base + 4 + i * 4;
                                    let v = read_u32(&owned, off).ok_or(DecryptError::Truncated)?
                                        as u64;
                                    let nv = if v >= moov_end {
                                        (v as i64 + delta) as u64
                                    } else {
                                        v
                                    };
                                    moov[off..off + 4].copy_from_slice(&(nv as u32).to_be_bytes());
                                }
                            }
                            b"co64" => {
                                let base = entry.start as usize + 8 + 4;
                                let count =
                                    read_u32(&owned, base).ok_or(DecryptError::Truncated)? as usize;
                                for i in 0..count {
                                    let off = base + 4 + i * 8;
                                    let v = read_u64(&owned, off).ok_or(DecryptError::Truncated)?;
                                    let nv = if v >= moov_end {
                                        (v as i64 + delta) as u64
                                    } else {
                                        v
                                    };
                                    moov[off..off + 8].copy_from_slice(&nv.to_be_bytes());
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

/// 重建单个 trak：改写 stbl、收集样本表。
/// 重建产物：改写字节 + 本轨首个加密样本区间。
type RebuiltTrack = Result<TrackRebuild, DecryptError>;

/// 单轨改写结果。
struct TrackRebuild {
    bytes: Vec<u8>,
    first_video: Option<(u64, u64)>,
    needs_avcc: bool,
}

fn rebuild_trak(data: &[u8], base: u64, trak: &BoxInfo, samples: &mut Vec<Sample>) -> RebuiltTrack {
    let trak_payload = payload_range(data, base, trak)?;
    let mut out = Vec::new();
    let mut head = TrackRebuild {
        bytes: Vec::new(),
        first_video: None,
        needs_avcc: false,
    };
    for child in children(data, base, trak_payload)? {
        if child.typ == *b"mdia" {
            let rebuilt = rebuild_mdia(data, base, &child, samples)?;
            out.extend_from_slice(&rebuilt.bytes);
            if head.first_video.is_none() {
                head.first_video = rebuilt.first_video;
            }
            head.needs_avcc |= rebuilt.needs_avcc;
        } else {
            out.extend_from_slice(box_bytes(data, base, &child)?);
        }
    }
    head.bytes = wrap_box(*b"trak", &out);
    Ok(head)
}

fn rebuild_mdia(data: &[u8], base: u64, mdia: &BoxInfo, samples: &mut Vec<Sample>) -> RebuiltTrack {
    let mdia_payload = payload_range(data, base, mdia)?;
    let mut out = Vec::new();
    let mut head = TrackRebuild {
        bytes: Vec::new(),
        first_video: None,
        needs_avcc: false,
    };
    for child in children(data, base, mdia_payload)? {
        if child.typ == *b"minf" {
            let rebuilt = rebuild_minf(data, base, &child, samples)?;
            out.extend_from_slice(&rebuilt.bytes);
            if head.first_video.is_none() {
                head.first_video = rebuilt.first_video;
            }
            head.needs_avcc |= rebuilt.needs_avcc;
        } else {
            out.extend_from_slice(box_bytes(data, base, &child)?);
        }
    }
    head.bytes = wrap_box(*b"mdia", &out);
    Ok(head)
}

fn rebuild_minf(data: &[u8], base: u64, minf: &BoxInfo, samples: &mut Vec<Sample>) -> RebuiltTrack {
    let minf_payload = payload_range(data, base, minf)?;
    let mut out = Vec::new();
    let mut head = TrackRebuild {
        bytes: Vec::new(),
        first_video: None,
        needs_avcc: false,
    };
    for child in children(data, base, minf_payload)? {
        if child.typ == *b"stbl" {
            let rebuilt = rebuild_stbl(data, base, &child, samples)?;
            out.extend_from_slice(&rebuilt.bytes);
            if head.first_video.is_none() {
                head.first_video = rebuilt.first_video;
            }
            head.needs_avcc |= rebuilt.needs_avcc;
        } else {
            out.extend_from_slice(box_bytes(data, base, &child)?);
        }
    }
    head.bytes = wrap_box(*b"minf", &out);
    Ok(head)
}

/// 重建 stbl 并收集该轨样本；返回改写结果（含首个视频加密样本与 avcC 需求）。
fn rebuild_stbl(data: &[u8], base: u64, stbl: &BoxInfo, samples: &mut Vec<Sample>) -> RebuiltTrack {
    let stbl_payload = payload_range(data, base, stbl)?;
    let kids = children(data, base, stbl_payload)?;
    for b in &kids {
        if b.typ == *b"seig" {
            return Err(DecryptError::Unsupported("sample group seig".to_owned()));
        }
    }
    let mut new_stsd: Option<Vec<u8>> = None;
    let mut track_enc_video = false;
    let mut track_needs_avcc = false;
    if let Some(stsd) = find(&kids, b"stsd") {
        let (rebuilt, detected, infos) = rebuild_stsd(data, base, stsd)?;
        if detected == Scheme::Unsupported {
            return Err(DecryptError::Unsupported("non-cenc scheme".to_owned()));
        }
        // 视频加密轨首样本 + avcC 缺失标记（合成用）。
        track_enc_video = infos.iter().any(|i| i.enc_video);
        track_needs_avcc = infos
            .iter()
            .any(|i| i.enc_video && i.restored == *b"avc1" && !i.has_config);
        new_stsd = Some(rebuilt);
    }
    let stsz = find(&kids, b"stsz")
        .map(|b| box_bytes(data, base, b))
        .transpose()?
        .map(|s| s.to_vec());
    let stsc = find(&kids, b"stsc")
        .map(|b| box_bytes(data, base, b))
        .transpose()?
        .map(|s| s.to_vec());
    let wide = find(&kids, b"co64").is_some();
    let co_box = find(&kids, b"stco").or(find(&kids, b"co64"));
    let track_samples = build_samples(data, base, stsz.as_deref(), stsc.as_deref(), co_box, wide)?;
    let ivs = read_ivs(data, base, &kids)?;
    let mut first_sample: Option<(u64, u64)> = None;
    if track_samples.is_empty() {
        // 空轨：直接放行。
    } else if ivs.is_empty() {
        if stsd_is_encrypted(data, base, find(&kids, b"stsd"))? {
            return Err(DecryptError::Unsupported(
                "encrypted track without IVs".to_owned(),
            ));
        }
        // 明文轨：不进样本表，直通。
    } else {
        if ivs.len() != track_samples.len() {
            return Err(DecryptError::Unsupported(format!(
                "iv/sample count mismatch ({} vs {})",
                ivs.len(),
                track_samples.len()
            )));
        }
        let before = samples.len();
        for (i, (start, end)) in track_samples.iter().enumerate() {
            samples.push(Sample {
                start: *start,
                end: *end,
                iv: ivs[i],
            });
        }
        // 记录本轨首个加密样本（视频轨用于取 SPS/PPS）。
        if track_enc_video && samples.len() > before {
            first_sample = Some((samples[before].start, samples[before].end));
        }
    }
    let mut out = Vec::new();
    for b in &kids {
        match &b.typ {
            b"senc" | b"saiz" | b"saio" | b"pssh" => continue,
            b"stsd" => {
                if let Some(ref rebuilt) = new_stsd {
                    out.extend_from_slice(rebuilt);
                }
            }
            _ => out.extend_from_slice(box_bytes(data, base, b)?),
        }
    }
    Ok(TrackRebuild {
        bytes: wrap_box(*b"stbl", &out),
        first_video: first_sample,
        needs_avcc: track_needs_avcc,
    })
}

fn stsd_is_encrypted(data: &[u8], base: u64, stsd: Option<&BoxInfo>) -> Result<bool, DecryptError> {
    let Some(stsd) = stsd else { return Ok(false) };
    let payload = payload_range(data, base, stsd)?;
    let entries = children(data, base, (payload.start + 8)..payload.end)?;
    Ok(entries
        .iter()
        .any(|e| e.typ == *b"encv" || e.typ == *b"enca"))
}

/// 加密方案。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scheme {
    Cenc,
    Unsupported,
}

/// 样本条目固定头长度（box 头 8 字节之外）：视频 78，音频 28，其他未知按 0
/// 处理（把整个 payload 当子盒区——调用方只对 encv/enca 使用此函数）。
fn entry_fixed_len(typ: &[u8; 4]) -> usize {
    match typ {
        b"encv" | b"avc1" | b"hev1" | b"hvc1" | b"avc3" | b"hvcC" => 78,
        b"enca" | b"mp4a" | b"ac-3" | b"ec-3" => 28,
        _ => 0,
    }
}

/// 条目子盒区（跳过固定头），坐标相对返回切片。
fn entry_children<'a>(
    entry_payload: &'a [u8],
    typ: &[u8; 4],
) -> Result<(&'a [u8], Vec<BoxInfo>), DecryptError> {
    let skip = entry_fixed_len(typ);
    if skip > entry_payload.len() {
        return Err(DecryptError::Truncated);
    }
    let region = &entry_payload[skip..];
    let kids = children(region, 0, 0..region.len())?;
    Ok((region, kids))
}

/// 单条目改写信息。
struct EntryInfo {
    enc_video: bool,
    restored: [u8; 4],
    has_config: bool,
}

/// 重建 stsd：`encv/enca` 去 `sinf` 并按 `frma` 还原编码；返回改写字节 +
/// 方案 + 逐条目信息。
fn rebuild_stsd(
    data: &[u8],
    base: u64,
    stsd: &BoxInfo,
) -> Result<(Vec<u8>, Scheme, Vec<EntryInfo>), DecryptError> {
    let payload = payload_range(data, base, stsd)?;
    let head = data
        .get(payload.start..payload.start + 8)
        .ok_or(DecryptError::Truncated)?
        .to_vec();
    let entries = children(data, base, (payload.start + 8)..payload.end)?;
    let mut body = Vec::new();
    let mut infos = Vec::new();
    for e in &entries {
        let raw = box_bytes(data, base, e)?;
        let is_enc = e.typ == *b"encv" || e.typ == *b"enca";
        let mut entry_payload = raw[8..].to_vec();
        // 默认还原目标；sinf/frma 给出原始编码时优先用它（不硬编码 avc1）。
        let mut restore = match &e.typ {
            b"encv" => *b"avc1",
            b"enca" => *b"mp4a",
            _ => e.typ,
        };
        let mut has_config = false;
        if is_enc {
            let (region, kids) = entry_children(&entry_payload, &e.typ)?;
            let mut kept = Vec::new();
            let skip = entry_fixed_len(&e.typ);
            for k in &kids {
                if k.typ == *b"sinf" {
                    if let Some(s) = read_scheme(region, k)?
                        && s != Scheme::Cenc
                    {
                        return Ok((Vec::new(), Scheme::Unsupported, Vec::new()));
                    }
                    if let Some(original) = read_frma(region, k)
                        && is_sane_fourcc(&original)
                    {
                        restore = original;
                    }
                    continue;
                }
                if k.typ == *b"avcC" || k.typ == *b"hvcC" || k.typ == *b"esds" {
                    has_config = true;
                }
                kept.extend_from_slice(&region[k.start as usize..(k.start + k.size) as usize]);
            }
            entry_payload = entry_payload[..skip].to_vec();
            entry_payload.extend_from_slice(&kept);
        }
        infos.push(EntryInfo {
            enc_video: e.typ == *b"encv",
            restored: restore,
            has_config,
        });
        body.extend_from_slice(&((entry_payload.len() + 8) as u32).to_be_bytes());
        body.extend_from_slice(&restore);
        body.extend_from_slice(&entry_payload);
    }
    let total = head.len() + body.len() + 8;
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(&(total as u32).to_be_bytes());
    out.extend_from_slice(b"stsd");
    out.extend_from_slice(&head);
    out.extend_from_slice(&body);
    Ok((out, Scheme::Cenc, infos))
}

/// 读 `sinf/frma` 原始编码（4 字节）；缺失返回 `None`。
fn read_frma(entry_payload: &[u8], sinf: &BoxInfo) -> Option<[u8; 4]> {
    let s = sinf.start as usize;
    let e = (sinf.start + sinf.size) as usize;
    let kids = children(entry_payload, 0, s + 8..e.min(entry_payload.len())).ok()?;
    let frma = find(&kids, b"frma")?;
    let off = frma.start as usize + 8;
    entry_payload
        .get(off..off + 4)
        .and_then(|b| b.try_into().ok())
}

/// fourcc 合法性：4 字节可打印 ASCII（防脏数据写坏 stsd）。
fn is_sane_fourcc(f: &[u8; 4]) -> bool {
    f.iter().all(|b| b.is_ascii_graphic() || *b == b' ')
}

/// 读 `sinf/schm/scheme_type`；缺失视为 cenc（与取流侧“有 spade 即解”一致）。
fn read_scheme(entry_payload: &[u8], sinf: &BoxInfo) -> Result<Option<Scheme>, DecryptError> {
    let s = sinf.start as usize;
    let e = (sinf.start + sinf.size) as usize;
    let kids = children(entry_payload, 0, s + 8..e.min(entry_payload.len()))?;
    for k in &kids {
        if k.typ == *b"schm" {
            let off = k.start as usize + 8 + 4;
            match entry_payload.get(off..off + 4) {
                Some(b"cenc") => return Ok(Some(Scheme::Cenc)),
                Some(_) => return Ok(Some(Scheme::Unsupported)),
                None => return Err(DecryptError::Truncated),
            }
        }
    }
    Ok(None)
}

/// 建样本表：stsz（全 0 则等长）+ stsc 分块 + stco/co64 偏移。
fn build_samples(
    data: &[u8],
    base: u64,
    stsz: Option<&[u8]>,
    stsc: Option<&[u8]>,
    co_box: Option<&BoxInfo>,
    wide: bool,
) -> Result<Vec<(u64, u64)>, DecryptError> {
    let stsz = stsz.ok_or_else(|| DecryptError::Unsupported("no stsz".to_owned()))?;
    let stsc = stsc.ok_or_else(|| DecryptError::Unsupported("no stsc".to_owned()))?;
    let co_box = co_box.ok_or_else(|| DecryptError::Unsupported("no stco".to_owned()))?;
    // 注意：以下偏移均按“完整 box（含 8 字节 size+type 头）”计算。
    let sample_size = read_u32(stsz, 12).ok_or(DecryptError::Truncated)?;
    let sample_count = read_u32(stsz, 16).ok_or(DecryptError::Truncated)? as usize;
    if sample_count > 50_000_000 {
        return Err(DecryptError::Unsupported("absurd sample count".to_owned()));
    }
    let mut sizes = Vec::with_capacity(sample_count.min(1_000_000));
    if sample_size == 0 {
        for i in 0..sample_count {
            sizes.push(read_u32(stsz, 20 + i * 4).ok_or(DecryptError::Truncated)? as u64);
        }
    } else {
        sizes.resize(sample_count, sample_size as u64);
    }
    let entry_count = read_u32(stsc, 12).ok_or(DecryptError::Truncated)? as usize;
    let co_bytes = box_bytes(data, base, co_box)?;
    let chunk_count = read_u32(co_bytes, 12).ok_or(DecryptError::Truncated)? as usize;
    let mut chunks = Vec::with_capacity(chunk_count);
    for i in 0..chunk_count {
        let off = if wide {
            read_u64(co_bytes, 16 + i * 8).ok_or(DecryptError::Truncated)?
        } else {
            read_u32(co_bytes, 16 + i * 4).ok_or(DecryptError::Truncated)? as u64
        };
        chunks.push(off);
    }
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for i in 0..entry_count {
        let first = read_u32(stsc, 16 + i * 12).ok_or(DecryptError::Truncated)? as usize;
        let per = read_u32(stsc, 20 + i * 12).ok_or(DecryptError::Truncated)? as usize;
        runs.push((first, per));
    }
    let mut out = Vec::with_capacity(sample_count);
    let mut sample_idx = 0usize;
    for (ri, (first, per)) in runs.iter().enumerate() {
        let last = if ri + 1 < runs.len() {
            runs[ri + 1].0
        } else {
            chunk_count + 1
        };
        for chunk in *first..last {
            if chunk == 0 || chunk > chunk_count {
                continue;
            }
            let mut off = chunks[chunk - 1];
            for _ in 0..*per {
                if sample_idx >= sample_count {
                    break;
                }
                let size = sizes[sample_idx];
                out.push((off, off + size));
                off += size;
                sample_idx += 1;
            }
        }
    }
    Ok(out)
}

/// 读 IV：`senc` 内联（8 字节 IV × N，无子样本表）；否则空（明文轨）。
fn read_ivs(data: &[u8], base: u64, kids: &[BoxInfo]) -> Result<Vec<[u8; 16]>, DecryptError> {
    let Some(senc) = find(kids, b"senc") else {
        return Ok(Vec::new());
    };
    let bytes = box_bytes(data, base, senc)?;
    // fullbox 头：size+type(8) + version/flags(4)，count 在其后。
    let mut pos = 12usize;
    let count = read_u32(bytes, pos).ok_or(DecryptError::Truncated)? as usize;
    pos += 4;
    if count > 5_000_000 {
        return Err(DecryptError::Unsupported("absurd senc count".to_owned()));
    }
    // 8 字节 IV × N（无子样本表）；若长度不符则尝试 16 字节。
    let rest = bytes.len().saturating_sub(pos);
    let iv_len = if rest == count * 8 {
        8
    } else if rest == count * 16 {
        16
    } else {
        return Err(DecryptError::Unsupported(
            "unexpected senc layout".to_owned(),
        ));
    };
    let mut out = Vec::with_capacity(count.min(1_000_000));
    for _ in 0..count {
        let raw = bytes
            .get(pos..pos + iv_len)
            .ok_or(DecryptError::Truncated)?;
        pos += iv_len;
        let mut iv = [0u8; 16];
        iv[..iv_len].copy_from_slice(raw);
        out.push(iv);
    }
    Ok(out)
}

/// 解密单个样本：CTR，计数器每样本从 IV 起（整样本加密）。
pub fn decrypt_sample(key: &[u8; 16], iv: &[u8; 16], data: &mut [u8]) {
    let cipher = Aes128::new(key.into());
    let mut counter = u128::from_be_bytes(*iv);
    for block in data.chunks_mut(16) {
        let mut ks = counter.to_be_bytes();
        cipher.encrypt_block((&mut ks).into());
        for (b, k) in block.iter_mut().zip(ks.iter()) {
            *b ^= *k;
        }
        counter = counter.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn box_raw(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&((payload.len() + 8) as u32).to_be_bytes());
        out.extend_from_slice(typ);
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn ctr_roundtrip() {
        let key = [7u8; 16];
        let iv = [3u8; 16];
        let mut data = b"hello cenc sample data....".to_vec();
        let plain = data.clone();
        decrypt_sample(&key, &iv, &mut data);
        assert_ne!(data, plain);
        decrypt_sample(&key, &iv, &mut data);
        assert_eq!(data, plain);
    }

    #[test]
    fn children_parses_flat_boxes() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&box_raw(b"ftyp", &[0u8; 8]));
        buf.extend_from_slice(&box_raw(b"moov", &[1u8; 4]));
        let kids = children(&buf, 0, 0..buf.len()).unwrap();
        assert_eq!(kids.len(), 2);
        assert_eq!(kids[0].typ, *b"ftyp");
    }

    #[test]
    fn subsample_decrypt_skips_clear_prefix() {
        // 整样本加密路径下，明文段不存在；此用例锁定“同 IV 重复解密可逆”。
        let key = [9u8; 16];
        let iv = [1u8; 16];
        let mut data = vec![0xAAu8; 100];
        let plain = data.clone();
        decrypt_sample(&key, &iv, &mut data);
        assert_ne!(&data[10..], &plain[10..]);
        decrypt_sample(&key, &iv, &mut data);
        assert_eq!(data, plain);
    }
}
