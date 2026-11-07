// ==============================================================================
// JAIB Theme Standalone Head-Injection Patch for Next.js Standalone server.js
// Purpose: Injects /themes/jaib/jaib-theme.css once into <head> with highest cascade
// precedence without brute-force chunk duplication.
// ==============================================================================

const fs = require('fs');
const path = '/app/targets/next/web/server.js';

if (!fs.existsSync(path)) {
  console.error('server.js not found at', path);
  process.exit(1);
}

let content = fs.readFileSync(path, 'utf8');

const hookCode = `
import http from 'node:http';

// JAIB Standalone Theme Injector (Highest Cascade Precedence)
const _origEmit = http.Server.prototype.emit;
http.Server.prototype.emit = function (event, req, res) {
  if (event === 'request' && res) {
    const _origWrite = res.write;
    const _origEnd = res.end;
    const _origWriteHead = res.writeHead;
    let isHtml = false;

    res.writeHead = function (status, msg, hdr) {
      const h = hdr || (typeof msg === 'object' ? msg : null);
      if (h) {
        for (const [k, v] of Object.entries(h)) {
          if (k.toLowerCase() === 'content-type' && String(v).includes('text/html')) {
            isHtml = true;
          }
        }
      }
      const ct = res.getHeader('content-type');
      if (ct && String(ct).includes('text/html')) isHtml = true;
      if (isHtml) {
        res.removeHeader('content-length');
      }
      return _origWriteHead.apply(res, arguments);
    };

    function checkContentType() {
      if (!isHtml) {
        const ct = res.getHeader('content-type');
        if (ct && String(ct).includes('text/html')) isHtml = true;
      }
    }

    const jaibTag = '<link id="jaib-theme-css" rel="stylesheet" href="/themes/jaib/jaib-theme.css?v=20261107-p4" /><script>(function(){var l=document.getElementById("jaib-theme-css");if(l&&l.parentNode){new MutationObserver(function(){if(l.nextElementSibling){l.parentNode.appendChild(l);}}).observe(document.head,{childList:true});}})();</script></head>';

    res.write = function (chunk, encoding, callback) {
      checkContentType();
      if (isHtml && chunk) {
        let str = chunk.toString();
        if (str.includes('</head>')) {
          str = str.replace('</head>', jaibTag);
          chunk = Buffer.from(str);
        }
      }
      return _origWrite.call(res, chunk, encoding, callback);
    };

    res.end = function (chunk, encoding, callback) {
      checkContentType();
      if (isHtml && chunk) {
        let str = chunk.toString();
        if (str.includes('</head>')) {
          str = str.replace('</head>', jaibTag);
          chunk = Buffer.from(str);
        }
      }
      return _origEnd.call(res, chunk, encoding, callback);
    };
  }
  return _origEmit.apply(this, arguments);
};
`;

if (!content.includes('JAIB Standalone Theme Injector')) {
  // Insert hook right after performance.mark
  content = content.replace("performance.mark('next-start');", "performance.mark('next-start');\n" + hookCode);
  fs.writeFileSync(path, content, 'utf8');
  console.log('[OK] Successfully patched server.js with JAIB standalone theme injector');
} else {
  console.log('[INFO] server.js already contains JAIB theme injector');
}

