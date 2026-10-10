use jxl::api::{
    JxlColorType, JxlDataFormat, JxlDecoder, JxlDecoderOptions, JxlOutputBuffer, JxlPixelFormat,
    ProcessingResult, check_signature, states,
};

/// Premultiplied RGBA with 8 bits per channel, rows packed without padding.
#[derive(Debug)]
pub struct RgbaImage {
    pub width: usize,
    pub height: usize,
    pub pixels: Box<[u8]>,
}

#[derive(Debug)]
pub enum JxlError {
    Decode(jxl::error::Error),
    Truncated,
    TooLarge,
}

impl From<jxl::error::Error> for JxlError {
    fn from(error: jxl::error::Error) -> Self {
        Self::Decode(error)
    }
}

pub fn is_jxl(data: &[u8]) -> bool {
    matches!(
        check_signature(data),
        ProcessingResult::Complete { result: Some(_) }
    )
}

/// Decodes the first frame of a complete JPEG XL file, with its orientation applied.
pub fn decode_jxl(mut data: &[u8]) -> Result<RgbaImage, JxlError> {
    let mut options = JxlDecoderOptions::default();
    options.premultiply_output = true;

    let initialized = JxlDecoder::<states::Initialized>::new(options);
    let mut decoder = complete(initialized, &mut data, |d, input| d.process(input, None))?;

    let info = decoder.basic_info();
    let (width, height) = info.size;
    let extra_channels = info.extra_channels.len();
    decoder.set_pixel_format(JxlPixelFormat {
        color_type: JxlColorType::Rgba,
        color_data_format: Some(JxlDataFormat::U8 { bit_depth: 8 }),
        extra_channel_format: vec![None; extra_channels],
    })?;

    let row_bytes = width.checked_mul(4).ok_or(JxlError::TooLarge)?;
    let length = row_bytes.checked_mul(height).ok_or(JxlError::TooLarge)?;
    let mut pixels = vec![0; length].into_boxed_slice();
    let mut output = JxlOutputBuffer::new(&mut pixels, height, row_bytes);
    let frame = complete(decoder, &mut data, |d, input| d.process(input, None))?;
    complete(frame, &mut data, |d, input| {
        d.process(input, std::slice::from_mut(&mut output), None)
    })?;

    Ok(RgbaImage {
        width,
        height,
        pixels,
    })
}

/// Drives one decoder step to completion; all input is in memory, so a step that needs more is truncated.
fn complete<D, T>(
    mut decoder: D,
    data: &mut &[u8],
    mut step: impl FnMut(D, &mut &[u8]) -> jxl::error::Result<ProcessingResult<T, D>>,
) -> Result<T, JxlError> {
    loop {
        let remaining = data.len();
        match step(decoder, data)? {
            ProcessingResult::Complete { result } => return Ok(result),
            ProcessingResult::NeedsMoreInput { fallback, .. } if data.len() < remaining => {
                decoder = fallback
            }
            ProcessingResult::NeedsMoreInput { .. } => return Err(JxlError::Truncated),
        }
    }
}
