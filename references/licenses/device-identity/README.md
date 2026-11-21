# Device identity fixture — license sources

Checked: 2026-11-17. This archive belongs to the independent opt-in [device-identity fixture](../../../scripts/fixtures/device-identity/). Its dependencies are outside the root package and shipping targets. [Research](../../authenticated-network-research.md#设备本地密钥续期与每用户-host-服务的可行性依据) explains the API/storage boundaries; [project status](../../../docs/project-status.md) owns runtime outcomes.

The compatible resolved set is pinned to:

| Package | Version / exact revision |
| --- | --- |
| [apple/swift-certificates](https://github.com/apple/swift-certificates) | revision `8789d7e78f996d56272836c8bf3590c5bd9c9754` |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | `5.1.1`, revision `f8fad2f95ad67b45f6340c0960e2396094d67e07` |
| [apple/swift-asn1](https://github.com/apple/swift-asn1) | `1.7.4`, revision `917b472dbe53ba699cbb0495f9a95a084bc6364d` |

[manifest.json](manifest.json) records the original source URL, exact revision/path, byte count and SHA-256 for these eight core files:

| Preserved text | Source / scope |
| --- | --- |
| [swift-certificates LICENSE](swift-certificates-LICENSE.txt) and [NOTICE](swift-certificates-NOTICE.txt) | Complete root files at the pin; Apache-2.0 plus upstream component/test attributions |
| [swift-crypto LICENSE](swift-crypto-LICENSE.txt) and [NOTICE](swift-crypto-NOTICE.txt) | Complete root files at the pin; Apache-2.0 plus upstream attributions |
| [swift-asn1 LICENSE](swift-asn1-LICENSE.txt) and [NOTICE](swift-asn1-NOTICE.txt) | Complete root files at the pin; Apache-2.0 plus upstream attributions |
| [musl MIT source notice](swift-certificates-musl-MIT.txt) | Exact leading comments from X509 `Sources/X509/X509BaseTypes/TimeCalculations.swift`, including the full Rich Felker/musl copyright, permission and disclaimer; the root NOTICE link is not a substitute for this text |
| [BoringSSL LICENSE](BoringSSL-LICENSE.txt) | Complete upstream LICENSE at `0226f30467f540a3f62ef48d453f93927da199b6`, the revision named by the pinned SwiftCrypto [vendoring metadata](https://github.com/apple/swift-crypto/blob/f8fad2f95ad67b45f6340c0960e2396094d67e07/Sources/CCryptoBoringSSL/hash.txt) |

The observed X509 dependency build includes CryptoExtras and vendored BoringSSL. This BoringSSL revision uses Apache-2.0; its full LICENSE also preserves separate Go TLS test-support BSD terms and explicitly states those test sources are not part of compiled libcrypto/libssl. Older NIOSSL/BoringSSL license characterizations are not interchangeable with this revision. No upstream implementation is copied into application code by this archive.

The root NOTICE files remain verbatim, including SwiftNIO/OpenAPI/wycheproof and X509 test-source attribution. They are provenance, not proof that every named component/test is linked. Additional read source notices outside this core archive include pinned SwiftCrypto's [XKCP metadata](https://github.com/apple/swift-crypto/blob/f8fad2f95ad67b45f6340c0960e2396094d67e07/Sources/CXKCP/vendored-sources.txt): it records only short revision `11297f5`; source headers include CC0 waivers and [Brian Gladman's separate three-condition notice](https://github.com/apple/swift-crypto/blob/f8fad2f95ad67b45f6340c0960e2396094d67e07/Sources/CXKCP/FIPS202-opt64/brg_endian.h). Do not label all XKCP CC0 or infer that XKCP/test vectors were linked. If those sources or tests are copied/distributed later, retain their applicable notices and expand this archive against the actual source/build set.

These texts do not license Munie's code or certify future shipping composition. A later dependency/pin or copied-source change must update the fixture lockfile, source attribution, applicable licenses and this hash manifest together.
