import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/bindings.g.dart';

String version() {
  final ptr = native_core_version();
  try {
    return ptr.cast<Utf8>().toDartString();
  } finally {
    native_core_free_string(ptr);
  }
}

/// Premultiplied RGBA, 8 bits per channel, owned by the native core: release it with [freeJxlPixels].
///
/// Addresses rather than pointers, so it can be returned from another isolate.
typedef JxlImage = ({int address, int width, int height, int rowBytes});

/// Whether the [length] bytes at [address] start with a JPEG XL signature.
bool isJxl(int address, int length) => native_core_is_jxl(Pointer.fromAddress(address), length);

/// Decodes the first frame of the JPEG XL file in the [length] bytes at [address], or returns null.
///
/// Blocks until done, so call it off the UI isolate.
JxlImage? decodeJxl(int address, int length) {
  final out = calloc<NativeCoreImage>();
  try {
    if (!native_core_decode_jxl(Pointer.fromAddress(address), length, out)) {
      return null;
    }
    final image = out.ref;
    return (address: image.pixels.address, width: image.width, height: image.height, rowBytes: image.row_bytes);
  } finally {
    calloc.free(out);
  }
}

void freeJxlPixels(JxlImage image) =>
    native_core_free_pixels(Pointer.fromAddress(image.address), image.rowBytes * image.height);
