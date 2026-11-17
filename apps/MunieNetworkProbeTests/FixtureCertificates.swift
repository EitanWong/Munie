import Foundation
import Security
import Testing

// Public, synthetic certificates generated solely for offline tests. Private keys were
// discarded at generation; these fixtures are never imported into a Keychain.
enum FixtureCertificate: Sendable {
  case trustedRoot, loopbackServer, wrongHostServer, foreignRoot

  func certificate() throws -> SecCertificate {
    let data = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    return try #require(SecCertificateCreateWithData(nil, data as CFData))
  }

  private var encoded: String {
    switch self {
    case .trustedRoot:
      """
      MIIBmDCCAT2gAwIBAgIUfYzFL3tqKqFw0TegeduTNOP7zCkwCgYIKoZIzj0EAwIwKDEmMCQGA1UEAwwd
      TXVuaWUgUHVibGljIFRlc3QgdHJ1c3RlZFJvb3QwHhcNMjYxMTE3MDQzMzQ2WhcNMzYxMTE0MDQzMzQ2
      WjAoMSYwJAYDVQQDDB1NdW5pZSBQdWJsaWMgVGVzdCB0cnVzdGVkUm9vdDBZMBMGByqGSM49AgEGCCqG
      SM49AwEHA0IABJ3IsnZ1FgAbyvnP10g/4K3je+B2B6CLoP3G5Wqaad/Q2dufsktUPxtPVYHDcRgqQqjK
      YEJk2OQOkTx0J/9B7sSjRTBDMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0GA1Ud
      DgQWBBQXfSuP1yJx8Uh+5e5pgs+C5fzRfzAKBggqhkjOPQQDAgNJADBGAiEAwGNTHL33sTUQh3I6/tEe
      Qg2A/OUQV7s3qRVNz8wWhxkCIQCWwFfbr7nq1A2R8WswFyW4mS3Ua1jyPxnABYSuxM/9yw==
      """
    case .loopbackServer:
      """
      MIIByzCCAXCgAwIBAgIBATAKBggqhkjOPQQDAjAoMSYwJAYDVQQDDB1NdW5pZSBQdWJsaWMgVGVzdCB0
      cnVzdGVkUm9vdDAeFw0yNjExMTcwNDMzNDZaFw0yNzExMTcwNDMzNDZaMCsxKTAnBgNVBAMMIE11bmll
      IFB1YmxpYyBUZXN0IGxvb3BiYWNrU2VydmVyMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/RDEUwEa
      3iw/UFiGPmD2zp1QutiIbY1NOq93+KpirjEpY/0U1oIkQofppbnk5YrSXcJImPPJKcrR0uL4N/VNoqOB
      hzCBhDAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAdBgNV
      HQ4EFgQUleCzLKtNQ3gN8xiqKoZzZxU7jgIwHwYDVR0jBBgwFoAUF30rj9cicfFIfuXuaYLPguX80X8w
      DwYDVR0RBAgwBocEfwAAATAKBggqhkjOPQQDAgNJADBGAiEAtQiuvhdFElObZ8OsRJEOPOGPxp5D4MOt
      0W/z4hXpYXECIQCkoOJ3mK19QTVyGG3emrLPa4AH1f9CO4XV8WkfFJTwvg==
      """
    case .wrongHostServer:
      """
      MIIB0DCCAXagAwIBAgIBAjAKBggqhkjOPQQDAjAoMSYwJAYDVQQDDB1NdW5pZSBQdWJsaWMgVGVzdCB0
      cnVzdGVkUm9vdDAeFw0yNjExMTcwNDMzNDZaFw0yNzExMTcwNDMzNDZaMCwxKjAoBgNVBAMMIU11bmll
      IFB1YmxpYyBUZXN0IHdyb25nSG9zdFNlcnZlcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMCyqC3u
      Q8wr5pk631bN/mjFbX1WpavjFtrIAP9yhrZCgrTircmmO50YRMklxz2pRTPskC1ELutXN/S/Y8XN3xej
      gYwwgYkwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYD
      VR0OBBYEFPPPKaDuLhuESvUv12IPxV6+4RTIMB8GA1UdIwQYMBaAFBd9K4/XInHxSH7l7mmCz4Ll/NF/
      MBQGA1UdEQQNMAuCCWxvY2FsaG9zdDAKBggqhkjOPQQDAgNIADBFAiBGAZRkWOodxz6k3erBhuT5iLkN
      ohFwIfXB4F9s9J3+qQIhAKH7VMRVzWXMW0gjgTxQ+7eCymzMXygzMdYH4XVMbkEQ
      """
    case .foreignRoot:
      """
      MIIBljCCAT2gAwIBAgIUUEEkWX3qbSkm3KG9PiduKpiE3RUwCgYIKoZIzj0EAwIwKDEmMCQGA1UEAwwd
      TXVuaWUgUHVibGljIFRlc3QgZm9yZWlnblJvb3QwHhcNMjYxMTE3MDQzMzQ2WhcNMzYxMTE0MDQzMzQ2
      WjAoMSYwJAYDVQQDDB1NdW5pZSBQdWJsaWMgVGVzdCBmb3JlaWduUm9vdDBZMBMGByqGSM49AgEGCCqG
      SM49AwEHA0IABD8NXdQnKSy0PH6Mt7r/Jcz/me9aTvQJPHSdT8+jKdut8801gqGsBtFxzEAnqzI8z+S8
      XrreJ7ySMSKjEPy6y36jRTBDMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0GA1Ud
      DgQWBBRdLAG/QQ3N6ISP0jH87dcBumv//jAKBggqhkjOPQQDAgNHADBEAiBqpE9KZ2K2H7iIAsDLNB71
      REVESgedAvGjTmmXxL6OCgIgenKn17rbIwaj6zc6jWpuGD+UVlzCfNeCbac14W3/yG4=
      """
    }
  }
}
