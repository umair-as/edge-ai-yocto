# DXRT_DYNAMIC_IPC_ENDPOINT must match dxrtd.service's RuntimeDirectory
# override in this recipe's files/dxrtd.service. Without it, libdxrt falls
# back to @dxrt_dynamic_ipc.sock (host network namespace) or
# /tmp/dxrt_dynamic_ipc.sock (hidden by dxrtd's PrivateTmp=yes), and every
# host-side dxrt client (dxrt-cli, run_model) fails to connect with
# error-code 264.
export DXRT_DYNAMIC_IPC_ENDPOINT=/run/dxrt/ipc.sock
