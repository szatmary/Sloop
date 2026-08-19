//
//  libssh2-internal.h
//  Sloop
//
//  Prototypes for libssh2 functions that are NOT part of its public API.
//  They are declared in libssh2's own src/crypto.h, which xcframeworks do not
//  ship, and they are linkable because the static library exports them.
//
//  Why depend on internals at all: agent forwarding has to sign with keys the
//  user imported, and modern ssh-keygen writes them in the OpenSSH container
//  format ("BEGIN OPENSSH PRIVATE KEY"). Neither CryptoKit, nor Security, nor
//  OpenSSL itself reads that container — libssh2 does, and it is already the
//  code path that authenticates every key-auth host today.
//
//  The risk this takes on: these signatures can change between libssh2
//  releases with no deprecation, because they were never public. The tripwire
//  is AgentSignerTests, which signs and then verifies through libssh2's own
//  verify functions — a drifted prototype fails the suite instead of shipping
//  signatures that remotes silently reject.
//

#ifndef LIBSSH2_INTERNAL_H
#define LIBSSH2_INTERNAL_H

#include <libssh2.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque to us. Under USE_OPENSSL_3 — which this build uses — all three are
   EVP_PKEY, and libssh2's own _libssh2_{rsa,ed25519,ecdsa}_free macros all
   expand to EVP_PKEY_free (openssl.h:341-347, 364-372). Those are macros, not
   symbols, so they cannot be linked; the free function is declared below and
   called directly. */
typedef void libssh2_ed25519_ctx;
typedef void libssh2_rsa_ctx;
typedef void libssh2_ecdsa_ctx;

/* Releases a key context from any of the *_new_private_frommemory calls.
   OpenSSL's, not libssh2's, but exported from the same static library. */
void EVP_PKEY_free(void *pkey);

/* Derives the algorithm name and wire-format public key blob from a private
   key in memory. This is how libssh2_userauth_publickey_frommemory works when
   the caller supplies no public key, and it is why Sloop needs no key
   derivation of its own on iOS, where imported keys have no .pub file. */
int _libssh2_pub_priv_keyfilememory(LIBSSH2_SESSION *session,
                                    unsigned char **method, size_t *method_len,
                                    unsigned char **pubkeydata, size_t *pubkeydata_len,
                                    const char *privatekeydata, size_t privatekeydata_len,
                                    const char *passphrase);

int _libssh2_ed25519_new_private_frommemory(libssh2_ed25519_ctx **ctx,
                                            LIBSSH2_SESSION *session,
                                            const char *filedata, size_t filedata_len,
                                            unsigned const char *passphrase);
int _libssh2_ed25519_sign(libssh2_ed25519_ctx *ctx, LIBSSH2_SESSION *session,
                          uint8_t **out_sig, size_t *out_sig_len,
                          const uint8_t *message, size_t message_len);
int _libssh2_ed25519_verify(libssh2_ed25519_ctx *ctx, const uint8_t *s,
                            size_t s_len, const uint8_t *m, size_t m_len);

int _libssh2_rsa_new_private_frommemory(libssh2_rsa_ctx **rsa,
                                        LIBSSH2_SESSION *session,
                                        const char *filedata, size_t filedata_len,
                                        unsigned const char *passphrase);
int _libssh2_rsa_sha2_sign(LIBSSH2_SESSION *session, libssh2_rsa_ctx *rsactx,
                           const unsigned char *hash, size_t hash_len,
                           unsigned char **signature, size_t *signature_len);
int _libssh2_rsa_sha2_verify(libssh2_rsa_ctx *rsa, size_t hash_len,
                             const unsigned char *sig, size_t sig_len,
                             const unsigned char *m, size_t m_len);

int _libssh2_ecdsa_new_private_frommemory(libssh2_ecdsa_ctx **ctx,
                                          LIBSSH2_SESSION *session,
                                          const char *filedata, size_t filedata_len,
                                          unsigned const char *passphrase);
int _libssh2_ecdsa_sign(LIBSSH2_SESSION *session, libssh2_ecdsa_ctx *ctx,
                        const unsigned char *hash, size_t hash_len,
                        unsigned char **signature, size_t *signature_len);
int _libssh2_ecdsa_verify(libssh2_ecdsa_ctx *ctx,
                          const unsigned char *r, size_t r_len,
                          const unsigned char *s, size_t s_len,
                          const unsigned char *m, size_t m_len);

#ifdef __cplusplus
}
#endif

#endif /* LIBSSH2_INTERNAL_H */
