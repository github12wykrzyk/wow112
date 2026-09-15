V68 artifact bundle is stored as an XZ-compressed tar archive in Base64 chunks under artifacts/V68/bundle/.

Reconstruction:
1. Concatenate part000.b64 ... part022.b64 in lexical order into bundle.b64.
2. Base64-decode to V68_ARTIFACTS.tar.xz.
3. Decompress XZ, then extract TAR.
4. Verify SHA256 values from manifests/SHA256_V68_RUNTIME.txt and the files inside the bundle.

The split form is intentional: it avoids connector limits/timeouts while preserving bytes exactly.
