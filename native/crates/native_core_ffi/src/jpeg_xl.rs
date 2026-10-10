use std::{ptr, slice};

use native_core::jpeg_xl;

use crate::guard;

/// Pixels decoded by this library: premultiplied RGBA, 8 bits per channel, rows `row_bytes` apart.
#[repr(C)]
pub struct NativeCoreImage {
    pub pixels: *mut u8,
    pub width: u32,
    pub height: u32,
    pub row_bytes: u32,
}

/// Returns whether the `len` bytes at `data` start with a JPEG XL signature.
///
/// # Safety
/// `data` must be readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_is_jxl(data: *const u8, len: usize) -> bool {
    if data.is_null() {
        return false;
    }
    // SAFETY: the caller guarantees `data` is readable for `len` bytes.
    let data = unsafe { slice::from_raw_parts(data, len) };
    guard(false, || jpeg_xl::is_jxl(data))
}

/// Decodes the first frame of the JPEG XL file in the `len` bytes at `data` into `out`. Returns
/// false and leaves `out` untouched if it cannot. Free the pixels with `native_core_free_pixels`.
///
/// # Safety
/// `data` must be readable for `len` bytes and `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_decode_jxl(
    data: *const u8,
    len: usize,
    out: *mut NativeCoreImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: the caller guarantees `data` is readable for `len` bytes.
    let data = unsafe { slice::from_raw_parts(data, len) };
    let Some(image) = guard(None, || jpeg_xl::decode_jxl(data).ok()) else {
        return false;
    };
    let (Ok(width), Ok(height), Ok(row_bytes)) = (
        u32::try_from(image.width),
        u32::try_from(image.height),
        u32::try_from(image.width * 4),
    ) else {
        return false;
    };

    let pixels = Box::into_raw(image.pixels).cast::<u8>();
    // SAFETY: the caller guarantees `out` is writable.
    unsafe {
        out.write(NativeCoreImage {
            pixels,
            width,
            height,
            row_bytes,
        })
    };
    true
}

/// Releases `len` bytes of pixels decoded by this library. Null is a no-op.
///
/// # Safety
/// `pixels` must come from `native_core_decode_jxl`, `len` must be its `row_bytes * height`, and
/// it must not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_free_pixels(pixels: *mut u8, len: usize) {
    if pixels.is_null() {
        return;
    }
    guard((), || {
        // SAFETY: the caller guarantees `pixels` and `len` describe a boxed slice from this library.
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(pixels, len)) });
    });
}

#[cfg(test)]
mod tests;
