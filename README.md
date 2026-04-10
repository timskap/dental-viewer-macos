# Dental Viewer

A native macOS viewer for dental **CBCT (cone-beam CT)** scans. Loads a folder
of DICOM slices, stacks them into a 3D volume, and renders them with a Metal
volume raycaster — plus three orthogonal MPR (multi-planar reformat) slice
views and an interactive cross-section / clipping plane.

Built specifically against the **Instrumentarium Dental OP300** OnDemand3D
disks (`IMGDATA/<date>/<series>/I*.dcm`), but works on any folder of DICOM
slices that uses one of the standard transfer syntaxes below.

## Features

- **Pure-Swift DICOM parser** — no external libraries.
  - Handles Explicit VR LE, Implicit VR LE, and JPEG-encapsulated PixelData
    (Baseline / Lossless / JPEG-LS / JPEG 2000) via `ImageIO`.
  - Falls back gracefully when `PixelSpacing` is empty (common on OP300).
- **Metal volume raycaster** with two modes:
  - **MIP** (Maximum Intensity Projection) — the default for CBCT bone /
    tooth visualization.
  - **Composite** (front-to-back alpha accumulation) — for soft surfaces.
- **Window / Level** sliders (center + width) for live contrast.
- **Axis-aligned clipping plane** — toggle, pick X / Y / Z, scrub a slider
  to slice the volume open. Flippable.
- **Three live MPR panes** — Axial, Coronal, Sagittal with per-pane scroll.
- **Drag** to orbit, **scroll** to zoom.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15+ (or just the Swift 5.9 toolchain for command-line builds)
- Apple Silicon or Intel with a Metal-capable GPU

## Run it

### Option A — open in Xcode (recommended)

```sh
open Package.swift
```

Xcode treats `Package.swift` as a full project. Pick the **DentalViewer**
scheme and hit ⌘R.

### Option B — command line

```sh
swift run DentalViewer
```

Then **File ▸ Open DICOM Folder…** (⌘O) and pick the series folder
(e.g. `IMGDATA/20260403/S0000017` on an OnDemand3D disk).

## CLI smoke tests

The same binary doubles as a tiny diagnostic tool when given flags:

```sh
# Parse a single .dcm file and dump its header
swift run DentalViewer --parse /path/to/I0005673.dcm

# Walk a folder, build the volume, and print its dimensions
swift run DentalViewer --load /path/to/IMGDATA/20260403/S0000017
```

## Project layout

```
Sources/DentalViewer/
├── main.swift                  CLI entry / falls through to SwiftUI app
├── App.swift                   SwiftUI App scene + menu commands
├── VolumeStore.swift           Observable model: volume + display state
├── DICOM/
│   ├── Volume.swift            3D voxel grid struct (8-bit, mm spacing)
│   ├── DICOMParser.swift       Pure-Swift DICOM file parser
│   └── SeriesLoader.swift      Folder → sorted slice stack → Volume
├── Rendering/
│   ├── ShaderSource.swift      Inline Metal raycaster source
│   └── VolumeMetalView.swift   MTKView + NSViewRepresentable + camera math
└── UI/
    ├── ContentView.swift       Toolbar + 3D pane + MPR stack + status bar
    └── MPRSliceView.swift      Single MPR pane (axial/coronal/sagittal)
```

## Notes & limitations

- The viewer treats voxel intensities as 8-bit grayscale. For 16-bit
  uncompressed series, each slice is rescaled per-slice to 8 bits before
  upload — fine for visualization, not appropriate for quantitative HU
  analysis.
- The clipping plane is axis-aligned. An arbitrary oblique plane would be a
  natural follow-up.
- No measurement tool yet — easy to add by sampling MPR pixel coordinates and
  multiplying by `Volume.spacing`.
- DICOMs with no `InstanceNumber` tag are sorted by `ImagePositionPatient.z`,
  then by filename (numeric-aware).
