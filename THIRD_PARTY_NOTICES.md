# Third-Party Notices

Nook's source and application distributions include the following third-party
materials:

## Sparkle 2.9.5

Sparkle is a secure software update framework for macOS, developed by the
Sparkle Project and contributors.

- Source: <https://github.com/sparkle-project/Sparkle>
- License: MIT, with additional notices for bundled components
- Complete license and external notices: `Sparkle-LICENSE.txt`

The complete license file is included with both the Nook source distribution
at `ThirdParty/Sparkle-LICENSE.txt` and the Nook application bundle.

## FluidAudio 0.17.4

FluidAudio is an on-device audio library for Apple platforms, developed by
Fluid Inference and contributors. Nook uses its offline speaker diarization
pipeline to separate the voices in a saved meeting.

- Source: <https://github.com/FluidInference/FluidAudio>
- License: Apache License 2.0. The complete license text is the same as Nook's
  own and is included as `LICENSE` in both the source distribution and the
  application bundle.

FluidAudio compiles in, and the Nook application therefore contains, the
following third-party works:

- **VBx clustering**, based on the VBx algorithm and reference implementation
  by BUT Speech@FIT, Brno University of Technology
  (<https://github.com/BUTSpeechFIT/VBx>). Copyright 2021-2024 BUT Speech@FIT.
  Apache License 2.0.
- **fastcluster**, hierarchical clustering routines. Licensed under the
  BSD 2-Clause license reproduced below.
- **text-processing-rs** (`NemoTextProcessing`), a text-normalization engine
  FluidAudio links by default. Nook never calls it. Apache License 2.0
  (<https://github.com/FluidInference/text-processing-rs>). It includes
  grammars derived from NVIDIA NeMo Text Processing (Copyright (c) NVIDIA
  CORPORATION & AFFILIATES, Apache License 2.0), rustfst (Copyright (c)
  Alexandre Caulier and the rustfst contributors, MIT OR Apache-2.0), flate2
  (Copyright (c) Alex Crichton and the flate2 contributors, MIT OR
  Apache-2.0), and further MIT or Apache-2.0 Rust crates listed in that
  project's `THIRD-PARTY-LICENSES.md`.

FluidAudio's Swift package also carries a small English pronunciation lexicon
for its text-to-speech module (`FluidAudio_FluidAudio.bundle`). Swift Package
Manager copies it into the application; Nook never loads it.

### fastcluster license

```
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Speaker diarization models (CC BY 4.0)

The application bundle includes Core ML speaker diarization models in
`SpeakerDiarizationModels`: `Segmentation.mlmodelc`, `FBank.mlmodelc`,
`Embedding.mlmodelc`, `PldaRho.mlmodelc` and `plda-parameters.json`. They are
not part of the source repository; `Scripts/fetch-diarization-models.sh`
downloads them at build time and verifies each file's SHA-256.

- Distributed by Fluid Inference as `FluidInference/speaker-diarization-coreml`,
  revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`:
  <https://huggingface.co/FluidInference/speaker-diarization-coreml>
- License: Creative Commons Attribution 4.0 International (CC BY 4.0),
  <https://creativecommons.org/licenses/by/4.0/>
- Nook redistributes these files unmodified.

These are modified works: Fluid Inference converted the PyTorch components of
pyannote's speaker-diarization-community-1 pipeline to Core ML, introduced fixed
and enumerated input shapes, applied mixed-precision storage, separated the
FBank frontend from the embedding backend, and compiled them for Apple
platforms. They are Core ML conversions, not fine-tuned models.

Attribution, as requested by Fluid Inference's notice for these artifacts:

- **pyannote**: the speaker-diarization-community-1 pipeline, segmentation and
  embedding checkpoints, published under CC BY 4.0,
  <https://huggingface.co/pyannote/speaker-diarization-community-1>.
- **WeSpeaker**: the ResNet34 speaker embedding model architecture and
  training recipe.
- **BUT Speech@FIT** (Brno University of Technology): the PLDA parameters
  (`plda.npz`, `xvec_transform.npz`), licensed by the rights holder under
  CC BY 4.0 including commercial use,
  <https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md>.
- **Fluid Inference**: the Core ML conversion and packaging.

Citations:

- Alexis Plaquet and Hervé Bredin. "Powerset multi-class cross entropy loss for
  neural speaker diarization." Proc. INTERSPEECH 2023.
- Hongji Wang, Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang, Xu
  Xiang, Yanlei Deng and Yanmin Qian. "Wespeaker: A research and production
  oriented speaker embedding learning toolkit." ICASSP 2023, IEEE
  International Conference on Acoustics, Speech and Signal Processing, pp. 1-5.
- Federico Landini, Ján Profant, Mireia Diez and Lukáš Burget. "Bayesian HMM
  clustering of x-vector sequences (VBx) in speaker diarization: theory,
  implementation and analysis on standard tasks." Computer Speech & Language,
  2022.

## Contributor Covenant 2.1

Nook's Code of Conduct is adapted from Contributor Covenant version 2.1,
created by the Contributor Covenant community and licensed under the
[Creative Commons Attribution 4.0 International License](https://creativecommons.org/licenses/by/4.0/).
The enforcement and reporting language has been adapted for this project.

- Source: <https://www.contributor-covenant.org/version/2/1/code_of_conduct.html>
