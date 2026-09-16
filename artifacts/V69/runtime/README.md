V69 accepted runtime recovery artifacts.

Exact accepted runtime binaries are preserved as XZ blobs in this directory:
- `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll.xz`
- `WoWControlHub.dll.xz`

Restored DLL identities:
- SpeedFloor SHA256 `a4dd0b0c44ecb4863231e0c92bab6767f3336003980fb552dc173448ab4b239c`, 9728 bytes.
- WoWControlHub SHA256 `f444a7c0c4769cc2f9546847fef54d41a0ccb79e823d132b73277e858571cf89`, 49152 bytes.

Accepted TEST provenance: work commit `112447c102226415bdd0d06de7c1e4c7c4946c54`, GitHub Actions artifact `10457293777`, inner package SHA256 `9f295803d0c305346407c6114dde3535eed3bfefe7c733ce0924e7d239352291`.

V69 intentionally excludes concurrent PickPocket/MovementCore experiments from that TEST package. The ControlHub source-to-runtime binary patch lineage is documented in `CONTROLHUB_BINARY_PATCH.txt`.
