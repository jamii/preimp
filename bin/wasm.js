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

    const parse = function (source) {
        const source_ptr = exports.inputAlloc(source.length);
        writeString(source_ptr, source);
        exports.parse();
        const output_ptr = exports.outputPtr();
        const output_len = exports.outputLen();
        return JSON.parse(readString(output_ptr, output_len));
    }

    const eval = function (value) {
        const input = JSON.stringify(value);
        const input_ptr = exports.inputAlloc(input.length);
        writeString(input_ptr, input);
        exports.eval();
        const output_ptr = exports.outputPtr();
        const output_len = exports.outputLen();
        return JSON.parse(readString(output_ptr, output_len));
    }

    return {
        wasm: wasm,
        parse: parse,
        eval: eval,
    };
};