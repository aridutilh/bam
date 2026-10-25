import Foundation
import JavaScriptCore

@main struct ExtensionWasmCompatibilityTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("Extension WASM compatibility: \(try run()) checks passed") }
        catch { fputs("FAIL: Extension WASM compatibility: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        let context = JSContext()!
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() ?? "JavaScript exception" }
        context.evaluateScript(#"""
        globalThis.location = {protocol:"webkit-extension:", host:"fixture-id", origin:"null"};
        globalThis.URL = class {
          constructor(raw) {
            const match = /^([a-z-]+:)[/][/](?:[^/@]*@)?([^/]+)(?:[/]|$)/.exec(raw);
            if (!match) throw new TypeError("bad URL");
            this.protocol = match[1]; this.host = match[2]; this.origin = "null";
          }
        };
        globalThis.calls = []; globalThis.nativeFailure = null;
        globalThis.fixtureBytes = new Uint8Array([0,97,115,109,1,0,0,0]).buffer;
        globalThis.Response = class {
          constructor(options = {}) {
            Object.assign(this, {url:"webkit-extension://fixture-id/module.wasm", status:200, ok:true, type:"basic", bodyUsed:false, body:{locked:false}, reads:0}, options);
            this.headers = {get: name => options.mime === undefined ? "application/octet-stream" : options.mime};
          }
          arrayBuffer() { this.reads++; return this.readFailure ? Promise.reject(this.readFailure) : Promise.resolve(fixtureBytes); }
        };
        const streaming = name => function (...args) {
          calls.push({name, args, receiver:this});
          return Promise.resolve(args[0]).then(response => {
            if (!(response instanceof Response)) throw new TypeError("native input error");
            return {route:name};
          });
        };
        const buffered = name => function (...args) {
          calls.push({name, args, receiver:this});
          return nativeFailure ? Promise.reject(nativeFailure) : Promise.resolve({route:name, module:"native module", instance:"native instance"});
        };
        globalThis.WebAssembly = {compile:buffered("compile"), instantiate:buffered("instantiate"), compileStreaming:streaming("compileStreaming"), instantiateStreaming:streaming("instantiateStreaming")};
        globalThis.originalCompileStreaming = WebAssembly.compileStreaming;
        globalThis.originalInstantiateStreaming = WebAssembly.instantiateStreaming;
        globalThis.originalCompile = WebAssembly.compile;
        globalThis.originalInstantiate = WebAssembly.instantiate;
        """#)
        context.evaluateScript(ExtensionWasmCompatibility.source)
        context.evaluateScript("globalThis.firstCompile = WebAssembly.compileStreaming; globalThis.firstInstantiate = WebAssembly.instantiateStreaming;")
        context.evaluateScript(ExtensionWasmCompatibility.source)
        context.evaluateScript(#"""
        globalThis.done = false; globalThis.failure = null; globalThis.checks = 0;
        (async () => {
          const check = (condition, message) => { if (!condition) throw new Error(message); checks++; };
          const reset = () => { calls.length = 0; nativeFailure = null; };
          const rejected = async (promise, expected, message) => { try { await promise; throw new Error(message + " resolved"); } catch (error) { check(error === expected, message); } };
          const options = {builtins:["js-string"]}, imports = {fixture:{imported:() => 42}};
          check(typeof document === "undefined" && typeof setTimeout === "undefined", "Fixture requires no DOM or timer environment");
          check(WebAssembly.compileStreaming === firstCompile && WebAssembly.instantiateStreaming === firstInstantiate, "Repeated injection does not wrap either API twice");
          reset(); const local = new Response(); let value = await WebAssembly.compileStreaming(local, options);
          check(value.route === "compile" && calls.length === 1 && local.reads === 1, "Wrong-MIME own response compiles native bytes once");
          check(calls[0].args[0] === fixtureBytes && calls[0].args[1] === options && calls[0].receiver === WebAssembly, "Compilation preserves exact bytes/options/native receiver");
          reset(); const overriddenBody = new Response(); overriddenBody.arrayBuffer = () => { throw new Error("not the response bytes"); };
          await WebAssembly.compileStreaming(overriddenBody);
          check(calls[0].args[0] === fixtureBytes && overriddenBody.reads === 1, "Captured Response reader retains original body bytes");
          reset(); const promised = new Response({mime:"text/plain"}); value = await WebAssembly.instantiateStreaming(Promise.resolve(promised), imports, options);
          check(value.route === "instantiate" && value.module === "native module" && value.instance === "native instance", "Instantiation preserves native result shape");
          check(calls.length === 1 && calls[0].args[0] === fixtureBytes && calls[0].args[1] === imports && calls[0].args[2] === options, "Instantiation retains imports and compile options");
          async function delegates(options, label) {
            reset(); const response = new Response(options); const receiver = {test:"receiver"};
            const result = await WebAssembly.compileStreaming.call(receiver, response, options);
            check(result.route === "compileStreaming" && calls.length === 1 && calls[0].args[0] === response && calls[0].args[1] === options && calls[0].receiver === receiver && response.reads === 0, label);
          }
          await delegates({mime:"application/wasm"}, "Correct MIME delegates unchanged");
          await delegates({mime:" Application/Wasm; charset=binary "}, "MIME essence uses native streaming validation");
          await delegates({url:"webkit-extension://other-id/module.wasm"}, "Different extension with null origin stays native");
          await delegates({url:"https://fixture-id/module.wasm"}, "Same host in a foreign protocol stays native");
          await delegates({url:"webkit-extension://fixture-id:123/module.wasm"}, "Different URL authority stays native");
          await delegates({url:"invalid URL"}, "Malformed response URL stays native");
          await delegates({url:""}, "Synthetic response without source URL stays native");
          for (const type of ["opaque","opaqueredirect","error"]) await delegates({type}, type + " response stays native");
          await delegates({status:404,ok:false}, "HTTP error stays native");
          await delegates({status:0,ok:true}, "Invalid successful status stays native");
          await delegates({bodyUsed:true}, "Consumed body stays native");
          await delegates({body:{locked:true}}, "Locked body stays native");
          reset(); const rejectedSource = new Error("fetch denied"); await rejected(WebAssembly.compileStreaming(Promise.reject(rejectedSource), options), rejectedSource, "Rejected source preserves original error");
          check(calls.length === 1 && calls[0].name === "compileStreaming", "Rejected source delegates to native streaming");
          reset(); let invalidError; try { await WebAssembly.compileStreaming({url:"webkit-extension://fixture-id/module.wasm",ok:true,status:200}); } catch (error) { invalidError = error; }
          check(invalidError instanceof TypeError && calls.length === 1 && calls[0].name === "compileStreaming", "Response-shaped objects receive native type validation");
          reset(); const readFailure = new Error("body stream failed"); const brokenBody = new Response({readFailure});
          await rejected(WebAssembly.compileStreaming(brokenBody), readFailure, "Body read failure is preserved");
          check(calls.length === 0 && brokenBody.reads === 1, "Failed body is not compiled or retried");
          reset(); const csp = new Error("CSP blocks wasm compilation"); nativeFailure = csp;
          await rejected(WebAssembly.compileStreaming(new Response()), csp, "Native CSP/compilation refusal is preserved");
          check(calls.length === 1 && calls[0].name === "compile", "Compilation failure cannot switch to another evaluation path");
          reset(); const invalidImports = new Error("invalid imports"); nativeFailure = invalidImports;
          await rejected(WebAssembly.instantiateStreaming(new Response(), imports, options), invalidImports, "Native import validation errors survive");
          reset(); let assimilations = 0;
          await WebAssembly.compileStreaming({then(resolve) { assimilations++; resolve(new Response({mime:"application/wasm"})); }});
          check(assimilations === 1 && calls[0].name === "compileStreaming", "Source thenables are assimilated once on delegation");
          reset(); let adaptedAssimilations = 0;
          await WebAssembly.instantiateStreaming({then(resolve) { adaptedAssimilations++; resolve(new Response()); }}, imports);
          check(adaptedAssimilations === 1 && calls[0].name === "instantiate", "Source thenables are assimilated once on adaptation");
          reset(); WebAssembly.compile = () => { throw new Error("replaced compile"); }; WebAssembly.instantiate = () => { throw new Error("replaced instantiate"); };
          await WebAssembly.compileStreaming(new Response()); await WebAssembly.instantiateStreaming(new Response());
          check(calls.map(call => call.name).join(",") === "compile,instantiate", "Both native byte compilers are captured at installation");
          globalThis.done = true;
        })().catch(error => { globalThis.failure = String(error); globalThis.done = true; });
        """#)
        let deadline = Date().addingTimeInterval(3)
        while context.objectForKeyedSubscript("done")?.toBool() != true && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        if let exception { throw Failure(description: exception) }
        guard context.objectForKeyedSubscript("done")?.toBool() == true else { throw Failure(description: "Promise fixture timed out") }
        let failure = context.objectForKeyedSubscript("failure")
        guard failure?.isNull == true else { throw Failure(description: failure?.toString() ?? "Unknown fixture failure") }
        let checks = Int(context.objectForKeyedSubscript("checks")!.toInt32())
        // A website must never acquire this adaptation, even if a caller injects
        // the script without the outer extension-origin compatibility guard.
        context.evaluateScript("location.protocol = 'https:'; WebAssembly.compileStreaming = originalCompileStreaming; WebAssembly.instantiateStreaming = originalInstantiateStreaming;")
        context.evaluateScript(ExtensionWasmCompatibility.source)
        guard context.evaluateScript("WebAssembly.compileStreaming === originalCompileStreaming && WebAssembly.instantiateStreaming === originalInstantiateStreaming")?.toBool() == true else { throw Failure(description: "Website context was patched") }
        return checks + 1
    }
}
