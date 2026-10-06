# BeatIt / Beat This! dependency

DJ Mix uses a pinned snapshot of **BeatIt** by Till Toenshoff at:

- commit `8d5f9ed80ddcdb8bbaea63d3dea26f137d366d01`
- https://github.com/tillt/BeatIt
- MIT License

BeatIt uses the **Beat This!** beat/downbeat model by Francesco Foscarin, Jan Schlüter and Gerhard Widmer.

- https://github.com/CPJKU/beat_this
- code and published model weights: MIT License

The dependency is fetched at build time and only the native Core ML / Accelerate / DBN path is compiled for iOS.
Torch, Python, CLI and dynamic plugin-loader components are not shipped.
