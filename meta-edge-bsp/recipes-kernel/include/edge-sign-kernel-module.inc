# Sign out-of-tree kernel modules that bypass the kernel's modules_install.
#
# CONFIG_MODULE_SIG_ALL signs modules installed through the kernel's
# modules_install target, which covers in-tree modules and any recipe using
# module.bbclass' default do_install. A recipe that overrides do_install and
# hand-installs its .ko never reaches that path and ships unsigned. Under
# CONFIG_MODULE_SIG_FORCE=y an unsigned module is rejected at load with ENOKEY.
#
# Signs with the key and hash the kernel itself used, so the module verifies
# against the built-in keyring. The kernel stages the key (EDGE_MODULE_SIG_KEY_REL)
# and certs/signing_key.x509 into ${STAGING_KERNEL_BUILDDIR}; only sign-file.c is
# staged, not the built tool, so it is compiled here against the native openssl.
#
# EDGE_SIGN_MODULES holds module basenames without the .ko suffix, as installed
# under ${nonarch_base_libdir}/modules/${KERNEL_VERSION}/extra/.

EDGE_SIGN_MODULES     ?= ""
EDGE_MODULE_SIG_HASH  ?= "sha512"

DEPENDS += "openssl-native"

edge_sign_kernel_modules() {
    certdir="${STAGING_KERNEL_BUILDDIR}/certs"
    key="${STAGING_KERNEL_BUILDDIR}/${EDGE_MODULE_SIG_KEY_REL}"
    if [ ! -f "${key}" ] || [ ! -f "${certdir}/signing_key.x509" ]; then
        bbfatal "No module signing key in ${certdir} — kernel built without CONFIG_MODULE_SIG"
    fi

    signsrc="${STAGING_KERNEL_DIR}/scripts/sign-file.c"
    if [ ! -f "${signsrc}" ]; then
        bbfatal "sign-file.c not staged at ${signsrc}"
    fi

    signtool="${WORKDIR}/edge-sign-file"
    ${BUILD_CC} ${BUILD_CFLAGS} ${BUILD_LDFLAGS} \
        -I${STAGING_INCDIR_NATIVE} -L${STAGING_LIBDIR_NATIVE} \
        -o "${signtool}" "${signsrc}" -lcrypto \
        || bbfatal "Failed to build sign-file from ${signsrc}"

    moddir="${D}${nonarch_base_libdir}/modules/${KERNEL_VERSION}/extra"
    for m in ${EDGE_SIGN_MODULES}; do
        ko="${moddir}/${m}.ko"
        if [ ! -f "${ko}" ]; then
            bbfatal "EDGE_SIGN_MODULES names ${m}, but ${ko} was not installed"
        fi
        # Strip debug info before signing: package.bbclass skips strip and
        # splitdebuginfo for signed modules (stripping invalidates the
        # trailer), so an unstripped signed .ko ships its .debug_* sections
        # and fails buildpaths QA on the TMPDIR paths inside them.
        ${STRIP} --strip-debug --remove-section=.comment \
            --remove-section=.note --preserve-dates "${ko}"
        "${signtool}" ${EDGE_MODULE_SIG_HASH} \
            "${key}" "${certdir}/signing_key.x509" "${ko}" \
            || bbfatal "sign-file failed on ${ko}"
        # A missing trailer here means the module fails to load under
        # MODULE_SIG_FORCE — fail the build rather than ship it.
        if ! tail -c 40 "${ko}" | grep -qa "Module signature appended"; then
            bbfatal "No signature trailer on ${ko} after signing"
        fi
    done
}

do_install[postfuncs] += "edge_sign_kernel_modules"
do_install[vardeps]   += "EDGE_SIGN_MODULES EDGE_MODULE_SIG_HASH"
