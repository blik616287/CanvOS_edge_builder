ARG BASE
FROM $BASE

ARG OS_DISTRIBUTION
ARG OS_VERSION
ARG PROXY_CERT_PATH
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG EDGE_APPLIANCE
ARG DOCA_DEB_PATH
ARG BFB_PATH
ARG BFB_FILENAME

RUN mkdir -p /certs
COPY certs/ /certs/
RUN if [ "${OS_DISTRIBUTION}" = "ubuntu" ]; then \
    cp -a /certs/. /usr/local/share/ca-certificates/ && \
    update-ca-certificates; \
    fi
RUN if [ "${OS_DISTRIBUTION}" = "opensuse-leap" ]; then \
    cp -a /certs/. /usr/share/pki/trust/anchors/ && \
    update-ca-certificates; \
    fi

RUN if [ "${OS_DISTRIBUTION}" = "rhel" ]; then \
    cp -a /certs/. /etc/pki/ca-trust/source/anchors/ && \
    update-ca-trust; \
    fi
RUN rm -rf /certs

# This file provides the ability to extend or override GPU specifications in the default lookup table
COPY overlay/files/etc/spectrocloud/custom-hardware-specs-lookup.json /etc/spectrocloud/custom-hardware-specs-lookup.json


########################### Edge Appliance Mode (AI-RA-Infra / DOCA) #######################

# When EDGE_APPLIANCE=true, pre-install all DOCA dependencies and firmware that nodeprep
# would normally install at runtime. Required because Kairos is an immutable OS.
RUN if [ "${EDGE_APPLIANCE}" = "true" ] && [ "${OS_DISTRIBUTION}" = "ubuntu" ]; then \
    if echo "${OS_VERSION}" | grep -q "^24"; then \
        GCC_PKG="gcc-14 libgcc-14-dev"; \
    else \
        GCC_PKG="gcc-12 libgcc-12-dev"; \
    fi && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        $GCC_PKG \
        lldpd \
        netplan.io \
        pv \
        psmisc \
        nfs-common \
        grepcidr && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# Install DOCA host package (registers DOCA apt repo, then installs doca-all with all components)
# After DOCA install, hold kernel-related packages to prevent conflicts with the Earthfile's
# apt-get upgrade step in +base-image, which would otherwise try to upgrade kernel headers
# and break DOCA's DKMS module dependencies.
#
# DOCA_DEB_PATH accepts a local file path OR a URL (http:// / https://).
# When a URL is provided, DOCA_DEB_LOCAL must be set to .empty-placeholder so COPY doesn't fail.
# When a local file is provided, DOCA_DEB_LOCAL should equal DOCA_DEB_PATH.
ARG DOCA_DEB_LOCAL
COPY ${DOCA_DEB_LOCAL:-.empty-placeholder} /tmp/doca-host-local.deb
RUN if [ "${EDGE_APPLIANCE}" = "true" ] && [ "${OS_DISTRIBUTION}" = "ubuntu" ]; then \
    case "${DOCA_DEB_PATH}" in \
        http://*|https://*) \
            echo "Downloading DOCA .deb from ${DOCA_DEB_PATH}..." && \
            curl -fSL -o /tmp/doca-host.deb "${DOCA_DEB_PATH}" ;; \
        *) \
            if [ -f /tmp/doca-host-local.deb ] && [ -s /tmp/doca-host-local.deb ]; then \
                mv /tmp/doca-host-local.deb /tmp/doca-host.deb; \
            fi ;; \
    esac && \
    if [ -f /tmp/doca-host.deb ] && [ -s /tmp/doca-host.deb ]; then \
        dpkg -i /tmp/doca-host.deb && \
        rm /tmp/doca-host.deb && \
        apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y doca-all && \
        apt-mark hold linux-headers-generic linux-image-generic \
            $(dpkg -l | awk '/^ii\s+linux-(headers|image|modules)-[0-9]/ {print $2}') 2>/dev/null || true && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*; \
    else \
        echo "ERROR: DOCA .deb not found (DOCA_DEB_PATH=${DOCA_DEB_PATH})"; exit 1; \
    fi; \
    else rm -f /tmp/doca-host-local.deb; fi

# Stage BFB firmware bundle for BlueField-3 adapters
#
# BFB_PATH accepts a local file path OR a URL (http:// / https://).
# When a URL is provided, BFB_LOCAL must be set to .empty-placeholder so COPY doesn't fail.
# When a local file is provided, BFB_LOCAL should equal BFB_PATH.
ARG BFB_LOCAL
COPY ${BFB_LOCAL:-.empty-placeholder} /tmp/bfb-local
RUN if [ "${EDGE_APPLIANCE}" = "true" ] && [ -n "${BFB_FILENAME}" ]; then \
    case "${BFB_PATH}" in \
        http://*|https://*) \
            echo "Downloading BFB firmware from ${BFB_PATH}..." && \
            curl -fSL -o /tmp/bfb-bundle "${BFB_PATH}" ;; \
        *) \
            if [ -f /tmp/bfb-local ] && [ -s /tmp/bfb-local ]; then \
                mv /tmp/bfb-local /tmp/bfb-bundle; \
            fi ;; \
    esac && \
    if [ -f /tmp/bfb-bundle ] && [ -s /tmp/bfb-bundle ]; then \
        mkdir -p /opt/spectrocloud/spcx/bfb && \
        mv /tmp/bfb-bundle "/opt/spectrocloud/spcx/bfb/${BFB_FILENAME}"; \
    else \
        echo "ERROR: BFB firmware not found (BFB_PATH=${BFB_PATH})"; exit 1; \
    fi; \
    else rm -f /tmp/bfb-local; fi

# Copy adapted nodeprep script (works on both mutable and immutable OS)
RUN if [ "${EDGE_APPLIANCE}" = "true" ]; then \
    mkdir -p /opt/spectrocloud; \
    fi
COPY overlay/files/opt/spectrocloud/nodeprep.sh /tmp/nodeprep.sh
RUN if [ "${EDGE_APPLIANCE}" = "true" ]; then \
    cp /tmp/nodeprep.sh /opt/spectrocloud/nodeprep.sh && \
    chmod +x /opt/spectrocloud/nodeprep.sh; \
    fi && \
    rm -f /tmp/nodeprep.sh

########################### Add any other image customizations here #######################

####  Examples  ####

### To install the nginx package for Ubuntu  ###

#TODO: Remove the following line. This is only for dev purpose.

# RUN useradd -m kairos && echo "kairos:kairos" | chpasswd
# RUN adduser kairos sudo
# RUN echo '%sudo ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# sbctl and mokutil are useful tools to check secure boot status, manage secure boot keys.
# RUN curl -Ls https://github.com/Foxboron/sbctl/releases/download/0.13/sbctl-0.13-linux-amd64.tar.gz | tar -xvzf - && mv sbctl/sbctl /usr/bin/sbctl
# RUN chmod +x /usr/bin/sbctl
# RUN apt-get update && apt-get install -y \
#     mokutil \
#     && apt-get clean

# RUN apt-get update && apt-get install nginx -y

### To install the nginx package for opensuse ###

# RUN zypper refresh && zypper install nginx -y

### To add a custom health script for two-node liveness checks ###

# ADD overlay/files/opt/spectrocloud/bin/check-disk-size.sh /opt/spectrocloud/bin/

### To install wifi prerequisites for Ubuntu ###

# RUN apt-get update && apt-get install wpasupplicant -y && \
#    apt-get update && apt-get install network-manager -y && \
#    apt-get install iputils-ping -y && \
#    mkdir /var/lib/wpa

# Ubuntu / Debian
#RUN if [ "${OS_DISTRIBUTION}" = "ubuntu" ]; then \
#      apt-get install -y qemu-guest-agent; \
#    fi

### To install the DRBD module package for Piraeus pack on Ubuntu  ###

# RUN apt-get update && \
#     apt-get upgrade -y && \
#     apt-get install --no-install-recommends -y \
#       ca-certificates \
#       kmod \
#       gpg \
#       make \
#       # Ubuntu has multiple kernel versions that may be using different gcc versions: use the dkms package to install them all
#       $(apt-get install -s dkms | awk '/^Inst gcc/{print $2}') \
#       patch \
#       diffutils \
#       perl \
#       elfutils \
#       libc-dev \
#       coccinelle \
#       curl && \
#     apt-get clean

# ARG DRBD_VERSION
# ADD https://pkg.linbit.com/downloads/drbd/9/drbd-${DRBD_VERSION}.tar.gz /drbd.tar.gz
# ADD --chmod=0755 https://raw.githubusercontent.com/LINBIT/drbd/master/docker/entry.sh /entry.sh

# ENV LB_HOW compile
# ENTRYPOINT /entry.sh
