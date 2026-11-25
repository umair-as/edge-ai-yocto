# linux-qcom selects the usecase firmware ath11k/QCA2066/hw2.1/nfa725/ for
# "arduino,monza" (amss.bin, m3.bin; board-2.bin stays in hw2.1/). It ships
# from linux-firmware 20261124; this append is redundant once PV >= 20261124.
NFA725_URI = "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20261124/ath11k/QCA2066/hw2.1/nfa725"

SRC_URI:append = " \
    ${NFA725_URI}/amss.bin;name=nfa725-amss;downloadfilename=linux-firmware-20261124-qca2066-nfa725-amss.bin;unpack=0 \
    ${NFA725_URI}/m3.bin;name=nfa725-m3;downloadfilename=linux-firmware-20261124-qca2066-nfa725-m3.bin;unpack=0 \
    ${NFA725_URI}/Notice.txt;name=nfa725-notice;downloadfilename=linux-firmware-20261124-qca2066-nfa725-Notice.txt;unpack=0 \
"
SRC_URI[nfa725-amss.sha256sum] = "c0f28a4393242633b4802cb1d93cf6b9d4eb2c089a6d1437e51fd35d06d59286"
SRC_URI[nfa725-m3.sha256sum] = "d20460e104b85a7be9cdb5199c4d8b94a9787912e3f920acd845694d4d71f730"
SRC_URI[nfa725-notice.sha256sum] = "770720d03de70ff503c6d9bb6f6932fc7833d078647fe8352c6d5d49d44bbc5f"

# Same WHENCE licence as the rest of ${PN}-ath11k-qca2066, whose FILES
# already covers the whole ath11k/QCA2066 directory.
do_install:append() {
    nfa725=${D}${firmwaredir}/ath11k/QCA2066/hw2.1/nfa725
    install -d $nfa725
    install -m 0644 ${UNPACKDIR}/linux-firmware-20261124-qca2066-nfa725-amss.bin $nfa725/amss.bin
    install -m 0644 ${UNPACKDIR}/linux-firmware-20261124-qca2066-nfa725-m3.bin $nfa725/m3.bin
    install -m 0644 ${UNPACKDIR}/linux-firmware-20261124-qca2066-nfa725-Notice.txt $nfa725/Notice.txt
}
