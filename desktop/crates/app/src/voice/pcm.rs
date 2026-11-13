//! Dictation's audio: whatever the input delivers, made 16 kHz mono (what
//! the recordings keep, whisper takes and the servers are sent), as 16-bit
//! PCM and as WAV.

/// The rate everything after capture runs at.
pub const RATE: u32 = 16_000;

/// Bytes of 16-bit mono PCM a second.
pub const BYTES_PER_SECOND: usize = RATE as usize * 2;

/// Half the resampling kernel's width, in input samples.
const HALF: usize = 16;

/// A streaming resampler to [`RATE`]: a windowed-sinc kernel (Blackman)
/// whose cutoff sits under the lower Nyquist, so 44.1 or 48 kHz speech
/// folds nothing back into the band the recognizers hear.
pub struct Resampler {
    from: u32,
    /// The output rate: [`RATE`], unless made with [`Resampler::to`].
    to: u32,
    /// Input samples per output sample.
    step: f64,
    /// Where the next output falls, in `buf`'s coordinates.
    at: f64,
    buf: Vec<f32>,
    /// The cutoff, as a fraction of the input's Nyquist.
    cutoff: f64,
}

impl Resampler {
    pub fn new(from: u32) -> Self {
        Self::to(from, RATE)
    }

    /// From `from` to `to` (a realtime call's voice runs at 24 kHz).
    pub fn to(from: u32, to: u32) -> Self {
        let from = from.max(1);
        let to = to.max(1);
        let cutoff = (f64::from(to) / f64::from(from)).min(1.0) * 0.92;
        Self {
            from,
            to,
            step: f64::from(from) / f64::from(to),
            // The first output lands where the kernel's left half is all
            // padding: silence before the first sample.
            at: HALF as f64,
            buf: vec![0.0; HALF],
            cutoff,
        }
    }

    pub fn input_rate(&self) -> u32 {
        self.from
    }

    /// Resamples `input` (more of the stream) and returns what is ready.
    pub fn push(&mut self, input: &[f32]) -> Vec<f32> {
        if self.from == self.to {
            return input.to_vec();
        }
        self.buf.extend_from_slice(input);
        let mut out = Vec::with_capacity((input.len() as f64 / self.step) as usize + 1);
        while self.at + (HALF as f64) < self.buf.len() as f64 {
            out.push(self.sample_at(self.at));
            self.at += self.step;
        }
        // Keep the kernel's left half behind the next output.
        let keep_from = (self.at.floor() as usize).saturating_sub(HALF);
        if keep_from > 0 {
            self.buf.drain(..keep_from);
            self.at -= keep_from as f64;
        }
        out
    }

    fn sample_at(&self, t: f64) -> f32 {
        let centre = t.floor() as isize;
        let mut acc = 0.0f64;
        let mut norm = 0.0f64;
        for k in (centre - HALF as isize + 1)..=(centre + HALF as isize) {
            if k < 0 || k as usize >= self.buf.len() {
                continue;
            }
            let x = t - k as f64;
            let w = kernel(x, self.cutoff);
            acc += f64::from(self.buf[k as usize]) * w;
            norm += w;
        }
        if norm.abs() < 1e-9 {
            0.0
        } else {
            (acc / norm) as f32
        }
    }
}

/// The windowed sinc at `x` input samples from the output's position.
fn kernel(x: f64, cutoff: f64) -> f64 {
    let half = HALF as f64;
    if x.abs() >= half {
        return 0.0;
    }
    let sinc = if x.abs() < 1e-9 {
        1.0
    } else {
        let a = std::f64::consts::PI * cutoff * x;
        a.sin() / a
    };
    // Blackman over [-HALF, HALF].
    let n = (x + half) / (2.0 * half);
    let tau = std::f64::consts::TAU;
    let window = 0.42 - 0.5 * (tau * n).cos() + 0.08 * (2.0 * tau * n).cos();
    cutoff * sinc * window
}

/// One mono channel from `channels` (a planar buffer each), averaged.
pub fn downmix(channels: &[&[f32]]) -> Vec<f32> {
    match channels {
        [] => vec![],
        [one] => one.to_vec(),
        many => {
            let len = many.iter().map(|c| c.len()).min().unwrap_or(0);
            let scale = 1.0 / many.len() as f32;
            (0..len)
                .map(|i| many.iter().map(|c| c[i]).sum::<f32>() * scale)
                .collect()
        }
    }
}

/// 16-bit little-endian PCM, clipped.
pub fn to_pcm16(samples: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(samples.len() * 2);
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

/// `pcm` (16 kHz mono 16-bit) as a WAV file, as core's `pcm16Wav` writes
/// one.
pub fn wav(pcm: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(44 + pcm.len());
    let len = pcm.len() as u32;
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(pcm);
    out
}

/// A WAV file's samples, mono, and its rate: 8-, 16-, 24- and 32-bit
/// integer PCM or 32-bit float, any number of channels.
pub fn decode_wav(bytes: &[u8]) -> Result<(Vec<f32>, u32), String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a WAV file".into());
    }
    let mut i = 12;
    let mut format: Option<(u16, u16, u32, u16)> = None;
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let size =
            u32::from_le_bytes([bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7]]) as usize;
        let body = i + 8;
        let end = (body + size).min(bytes.len());
        match id {
            b"fmt " if size >= 16 => {
                let u16_at = |o: usize| u16::from_le_bytes([bytes[body + o], bytes[body + o + 1]]);
                let mut tag = u16_at(0);
                let channels = u16_at(2);
                let rate = u32::from_le_bytes([
                    bytes[body + 4],
                    bytes[body + 5],
                    bytes[body + 6],
                    bytes[body + 7],
                ]);
                let bits = u16_at(14);
                // WAVE_FORMAT_EXTENSIBLE: the real tag opens the sub-format.
                if tag == 0xFFFE && size >= 26 {
                    tag = u16_at(24);
                }
                format = Some((tag, channels.max(1), rate, bits));
            }
            b"data" => {
                let (tag, channels, rate, bits) = format.ok_or("data before fmt")?;
                let data = &bytes[body..end];
                let samples = decode_samples(data, tag, bits)?;
                let channels = usize::from(channels);
                let mono = samples
                    .chunks(channels)
                    .filter(|frame| frame.len() == channels)
                    .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                    .collect();
                return Ok((mono, rate));
            }
            _ => {}
        }
        // Chunks are padded to an even length.
        i = body + size + (size & 1);
    }
    Err("no audio in the WAV file".into())
}

fn decode_samples(data: &[u8], tag: u16, bits: u16) -> Result<Vec<f32>, String> {
    Ok(match (tag, bits) {
        (1, 8) => data
            .iter()
            .map(|b| (f32::from(*b) - 128.0) / 128.0)
            .collect(),
        (1, 16) => data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| f32::from(i16::from_le_bytes(*c)) / 32768.0)
            .collect(),
        (1, 24) => data
            .as_chunks::<3>()
            .0
            .iter()
            .map(|c| {
                let v = i32::from_le_bytes([0, c[0], c[1], c[2]]) >> 8;
                v as f32 / 8_388_608.0
            })
            .collect(),
        (1, 32) => data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| i32::from_le_bytes(*c) as f32 / 2_147_483_648.0)
            .collect(),
        (3, 32) => data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| f32::from_le_bytes(*c))
            .collect(),
        _ => return Err(format!("WAV format {tag} at {bits} bits is not supported")),
    })
}

/// The RMS level of `samples` in dBFS (-120 for silence).
pub fn level_db(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return -120.0;
    }
    let mean = samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32;
    if mean <= 1e-12 {
        -120.0
    } else {
        (10.0 * mean.log10()).max(-120.0)
    }
}

/// A meter's reading for a level: -60 dBFS and under is empty, 0 full.
pub fn meter(db: f32) -> f32 {
    ((db + 60.0) / 60.0).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(rate: u32, hz: f32, seconds: f32) -> Vec<f32> {
        let n = (rate as f32 * seconds) as usize;
        (0..n)
            .map(|i| (std::f32::consts::TAU * hz * i as f32 / rate as f32).sin() * 0.5)
            .collect()
    }

    fn rms(s: &[f32]) -> f32 {
        (s.iter().map(|v| v * v).sum::<f32>() / s.len() as f32).sqrt()
    }

    #[test]
    fn speech_band_tones_survive_resampling_from_48_and_44_1_khz() {
        for rate in [48_000, 44_100, 22_050] {
            let input = sine(rate, 1_000.0, 1.0);
            let mut r = Resampler::new(rate);
            // In uneven pieces, as a tap delivers them.
            let mut out = vec![];
            for piece in input.chunks(997) {
                out.extend(r.push(piece));
            }
            let expected = 16_000.0;
            assert!(
                (out.len() as f32 - expected).abs() < 40.0,
                "{rate}: {} samples",
                out.len()
            );
            // Away from the edges, the tone keeps its level (0.5 peak).
            let middle = &out[2_000..14_000];
            assert!((rms(middle) - 0.5 / 2f32.sqrt()).abs() < 0.01, "{rate}");
        }
    }

    #[test]
    fn a_tone_above_the_new_nyquist_is_filtered_out() {
        let input = sine(48_000, 12_000.0, 1.0);
        let mut r = Resampler::new(48_000);
        let out = r.push(&input);
        assert!(rms(&out[2_000..14_000]) < 0.02, "aliased: {}", rms(&out));
    }

    #[test]
    fn sixteen_khz_passes_through() {
        let input = sine(16_000, 440.0, 0.1);
        assert_eq!(Resampler::new(16_000).push(&input), input);
    }

    #[test]
    fn channels_average_into_one() {
        assert_eq!(downmix(&[&[1.0, 0.0], &[0.0, 0.0]]), vec![0.5, 0.0]);
        assert_eq!(downmix(&[&[0.25]]), vec![0.25]);
    }

    #[test]
    fn pcm_round_trips_through_wav() {
        let samples = vec![0.0, 0.5, -0.5, 1.5, -1.5];
        let pcm = to_pcm16(&samples);
        assert_eq!(pcm.len(), 10);
        let file = wav(&pcm);
        assert_eq!(&file[0..4], b"RIFF");
        assert_eq!(file.len(), 44 + 10);
        let (back, rate) = decode_wav(&file).unwrap();
        assert_eq!(rate, 16_000);
        assert_eq!(back.len(), 5);
        assert!((back[1] - 0.5).abs() < 1e-3);
        // Clipped, not wrapped.
        assert!(back[3] > 0.99 && back[4] < -0.99);
    }

    #[test]
    fn stereo_float_wav_decodes_to_mono() {
        let mut data = vec![];
        for (l, r) in [(0.5f32, 0.0f32), (1.0, 1.0)] {
            data.extend_from_slice(&l.to_le_bytes());
            data.extend_from_slice(&r.to_le_bytes());
        }
        let mut file = b"RIFF\0\0\0\0WAVE".to_vec();
        file.extend_from_slice(b"fmt ");
        file.extend_from_slice(&16u32.to_le_bytes());
        file.extend_from_slice(&3u16.to_le_bytes());
        file.extend_from_slice(&2u16.to_le_bytes());
        file.extend_from_slice(&44_100u32.to_le_bytes());
        file.extend_from_slice(&(44_100u32 * 8).to_le_bytes());
        file.extend_from_slice(&8u16.to_le_bytes());
        file.extend_from_slice(&32u16.to_le_bytes());
        // An odd-sized chunk before the audio, padded.
        file.extend_from_slice(b"LIST");
        file.extend_from_slice(&3u32.to_le_bytes());
        file.extend_from_slice(b"abc\0");
        file.extend_from_slice(b"data");
        file.extend_from_slice(&(data.len() as u32).to_le_bytes());
        file.extend_from_slice(&data);
        let (mono, rate) = decode_wav(&file).unwrap();
        assert_eq!(rate, 44_100);
        assert_eq!(mono, vec![0.25, 1.0]);
        assert!(decode_wav(b"not a wav").is_err());
    }

    #[test]
    fn levels_read_in_dbfs() {
        assert_eq!(level_db(&[0.0; 10]), -120.0);
        let full = vec![1.0f32; 10];
        assert!(level_db(&full).abs() < 0.01);
        assert!((level_db(&[0.1; 10]) + 20.0).abs() < 0.01);
        assert_eq!(meter(-80.0), 0.0);
        assert_eq!(meter(0.0), 1.0);
        assert!((meter(-30.0) - 0.5).abs() < 1e-6);
    }
}
