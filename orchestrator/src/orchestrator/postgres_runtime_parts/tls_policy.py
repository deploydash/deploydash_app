def postgres_tls_key_pair_check_shell(certificate_ref, private_key_ref):
    """Render the shared fail-closed proof that a certificate matches its key."""
    return (
        'TLS_CERTIFICATE_PUBLIC_KEY="$(openssl x509 -in '
        f'{certificate_ref} -pubkey -noout)"; '
        'TLS_PRIVATE_KEY_PUBLIC_KEY="$(openssl pkey -in '
        f'{private_key_ref} -pubout)"; '
        'test -n "${TLS_CERTIFICATE_PUBLIC_KEY}"; '
        'test "${TLS_CERTIFICATE_PUBLIC_KEY}" = "${TLS_PRIVATE_KEY_PUBLIC_KEY}"; '
    )
