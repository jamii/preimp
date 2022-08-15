async function Preimp(preimp_url) {
    const wasm = await WebAssembly.instantiateStreaming(fetch(preimp_url), {env: {}});

    return {
        wasm: wasm,
    };
};