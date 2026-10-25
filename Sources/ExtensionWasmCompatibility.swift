import Foundation

/// WebKit can serve packaged .wasm with a generic MIME type. Keep compilation
/// in the native WebAssembly APIs (including their CSP and validation checks),
/// and adapt only readable responses from this exact extension's URL authority.
enum ExtensionWasmCompatibility {
    static let source = #"""
    (() => {
      "use strict";
      const wasm = globalThis.WebAssembly;
      const ResponseClass = globalThis.Response;
      const URLClass = globalThis.URL;
      const here = globalThis.location;
      if (!wasm || typeof ResponseClass !== "function" || typeof URLClass !== "function" || !here) return;
      const protocol = here.protocol, host = here.host;
      if (!["webkit-extension:", "moz-extension:", "chrome-extension:"].includes(protocol) || !host) return;
      const marker = Symbol.for("com.ari.bam.wasm-streaming.v1");
      const resolve = Promise.resolve.bind(Promise);
      const reject = Promise.reject.bind(Promise);
      const apply = Reflect.apply;
      const readBody = ResponseClass.prototype.arrayBuffer;
      if (typeof readBody !== "function") return;
      const compile = wasm.compile, instantiate = wasm.instantiate;
      const compileStreaming = wasm.compileStreaming, instantiateStreaming = wasm.instantiateStreaming;
      function eligible(response) {
        try {
          if (!(response instanceof ResponseClass) || !response.ok || response.status < 200 || response.status >= 300 ||
              ["opaque", "opaqueredirect", "error"].includes(response.type) || response.bodyUsed || response.body?.locked) return false;
          const url = new URLClass(response.url);
          // Custom URL schemes may all report origin === "null". Compare the
          // actual protocol and host so another extension never becomes local.
          if (url.protocol !== protocol || url.host !== host) return false;
          const mime = (response.headers.get("Content-Type") || "").split(";", 1)[0].trim().toLowerCase();
          return mime !== "application/wasm";
        } catch (_) { return false; }
      }
      function install(name, streaming, buffered) {
        if (typeof streaming !== "function" || typeof buffered !== "function" || streaming[marker]) return;
        const wrapper = function (source, ...argumentsAfterSource) {
          const receiver = this;
          // Assimilate arbitrary thenables only once. Delegation receives the
          // same settled Response/error, while imports/options stay untouched.
          return resolve(source).then(response => {
            if (!eligible(response)) return apply(streaming, receiver, [response, ...argumentsAfterSource]);
            return resolve(apply(readBody, response, [])).then(bytes => apply(buffered, wasm, [bytes, ...argumentsAfterSource]));
          }, error => apply(streaming, receiver, [reject(error), ...argumentsAfterSource]));
        };
        Object.defineProperty(wrapper, marker, { value: true });
        // Read-only native surfaces are left intact. No fetch, Response, CSP or
        // WebAssembly validation behavior is replaced by this adapter.
        try { wasm[name] = wrapper; } catch (_) {}
      }
      install("compileStreaming", compileStreaming, compile);
      install("instantiateStreaming", instantiateStreaming, instantiate);
    })();
    """#
}
