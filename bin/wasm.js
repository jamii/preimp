async function Preimp(preimp_url) {
    var wasm = undefined;

    const writeString = function (string_ptr, string) {
        const bytes = new Uint8Array(wasm.instance.exports.memory.buffer);
        const encoded = new TextEncoder().encode(string);
        bytes.set(encoded, string_ptr);
    }

    const readString = function (string_ptr, string_len) {
        const bytes = new Uint8Array(wasm.instance.exports.memory.buffer);
        const string = new TextDecoder().decode(bytes.slice(string_ptr, string_ptr + string_len));
        return string;
    }

    const jsLog = function(string_ptr, string_len) {
        const string = readString(string_ptr, string_len);
        console.log(string);
    }

    const jsPanic = function(string_ptr, string_len) {
        const string = readString(string_ptr, string_len);
        console.error(string);
        throw string;
    }

    wasm = await WebAssembly.instantiateStreaming(fetch(preimp_url), {env: {
        jsLog: jsLog,
        jsPanic: jsPanic,
    }});
    const exports = wasm.instance.exports;

    const eval = function (source) {
        const source_ptr = exports.evalSourceAlloc(source.length);
        writeString(source_ptr, source);
        exports.eval();
        const result_ptr = exports.evalResultPtr();
        const result_len = exports.evalResultLen();
        return JSON.parse(readString(result_ptr, result_len));
    }

    return {
        wasm: wasm,
        eval: eval,
    };
};