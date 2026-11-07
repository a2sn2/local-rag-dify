// ==============================================================================
// JAIB Theme - Runtime Server Patch (DEPRECATED & SAFELY INACTIVE)
// Note: Runtime monkey-patching of Next.js server.js res.write/res.end has been
// superseded by static CSS chunk bundling in Dockerfile.jaib-web.
// Next.js compression middleware streams pre-compressed GZIP/Brotli buffers to
// http.Server, making runtime UTF-8 string manipulation unsafe and prone to
// ERR_CONTENT_DECODING_FAILED.
// CSS is now reliably appended to static chunks during image build.
// ==============================================================================

console.log('[INFO] patch-server.js: Runtime server patching is deprecated. Theme is statically bundled.');
