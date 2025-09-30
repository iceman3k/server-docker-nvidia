# ==============================================================
# 1️⃣ Base image – Ubuntu 22.04 (Jammy) + Manual Node.js 20 install
# ==============================================================
FROM nvidia/cuda:13.0.1-devel-ubuntu22.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y ca-certificates curl gnupg
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 
RUN apt-get install -y nodejs

# ==============================================================
# 2️⃣ Stage to install FFmpeg dependencies
# ==============================================================
FROM base AS ffmpeg-deps

ENV PATH="/usr/local/bin:/usr/local/cuda/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

RUN apt-get update && apt-get install -y git
RUN git config --global advice.detachedHead false

# Install nv-codec-headers
RUN git clone https://github.com/FFmpeg/nv-codec-headers.git /usr/src/nv-codec-headers && \
    cd /usr/src/nv-codec-headers && \
    make install

# Enable multiverse repository for non-free codecs like fdk-aac
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy multiverse" > /etc/apt/sources.list.d/multiverse.list && \
    echo "deb http://archive.ubuntu.com/ubuntu/ jammy-updates multiverse" >> /etc/apt/sources.list.d/multiverse.list

# Install build dependencies
RUN BUILD_DEPS=" \
    gnutls-bin \
    libfreetype-dev \
    libgnutls28-dev \
    libmp3lame-dev \
    libass-dev \
    libogg-dev \
    libtheora-dev \
    libvorbis-dev \
    libvpx-dev \
    libwebp-dev \
    libssh2-1-dev \
    libopus-dev \
    librtmp-dev \
    libx264-dev \
    libx265-dev \
    yasm \
    build-essential \
    nasm \
    libdav1d-dev \
    libbluray-dev \
    libdrm-dev \
    libzimg-dev \
    libaom-dev \
    libxvidcore-dev \
    libfdk-aac-dev \
    libva-dev \
    git \
    x264 \
    " && \
    apt-get update && \
    apt-get install -y --no-install-recommends $BUILD_DEPS && \
    rm -rf /var/lib/apt/lists/*

# ==============================================================
# 3️⃣ Stage to build Jellyfin-FFmpeg
# ==============================================================
FROM ffmpeg-deps AS ffmpeg-build

ENV BIN="/usr/bin"

# Replace nvcc with a wrapper
RUN ls -l /usr/local/cuda/bin && \
    which nvcc && \
    mv /usr/local/cuda/bin/nvcc /usr/local/cuda/bin/nvcc.original
COPY nvcc-wrapper.sh /usr/local/cuda/bin/nvcc
RUN chmod +x /usr/local/cuda/bin/nvcc

# Diagnostic: Test the wrapper to ensure it's called and logs are generated
RUN nvcc --version && \
    cat /usr/src/nvcc-wrapper.log || true && \
    echo "Wrapper test complete"

# Clone and build Jellyfin-FFmpeg
RUN DIR=$(mktemp -d) && \
    cd "${DIR}" && \
    git clone --depth 1 --branch v7.1.2-1 https://github.com/jellyfin/jellyfin-ffmpeg.git && \
    cd jellyfin-ffmpeg* && \
    \
    # Detect CUDA version from nvcc
    CUDA_VERSION=$(nvcc --version | grep "release" | sed -E 's/.*release ([0-9]+)\.([0-9]+).*/\1.\2/') && \
    \
    # Set NVCCFLAGS based on CUDA version
    if [ "$CUDA_VERSION" = "12.3" ]; then \
        NVCCFLAGS="-Xptxas -O0 \
            -gencode arch=compute_60,code=sm_60 \
            -gencode arch=compute_61,code=sm_61 \
            -gencode arch=compute_70,code=sm_70 \
            -gencode arch=compute_75,code=sm_75 \
            -gencode arch=compute_80,code=sm_80 \
            -gencode arch=compute_86,code=sm_86 \
            -gencode arch=compute_87,code=sm_87 \
            -gencode arch=compute_89,code=sm_89"; \
    elif [ "$CUDA_VERSION" = "13.0" ] || [ "$CUDA_VERSION" = "13.1" ]; then \
        NVCCFLAGS="-Xptxas -O0 \
            -gencode arch=compute_75,code=sm_75 \
            -gencode arch=compute_80,code=sm_80 \
            -gencode arch=compute_86,code=sm_86 \
            -gencode arch=compute_87,code=sm_87 \
            -gencode arch=compute_89,code=sm_89 \
            -gencode arch=compute_90,code=sm_90"; \
    elif [ "$CUDA_VERSION" = "13.2" ] || [ "$CUDA_VERSION" = "13.3" ] || [ "$CUDA_VERSION" = "13.4" ] || [ "$CUDA_VERSION" = "13.5" ] || [ "$CUDA_VERSION" = "13.6" ]; then \
        NVCCFLAGS="-Xptxas -O0 \
            -gencode arch=compute_75,code=sm_75 \
            -gencode arch=compute_80,code=sm_80 \
            -gencode arch=compute_86,code=sm_86 \
            -gencode arch=compute_87,code=sm_87 \
            -gencode arch=compute_89,code=sm_89 \
            -gencode arch=compute_90,code=sm_90 \
            -gencode arch=compute_100,code=sm_100"; \
    else \
        echo "Unsupported CUDA version: $CUDA_VERSION" >&2; \
        exit 1; \
    fi && \
    \
    # Configure and build ffmpeg
    ./configure --bindir="$BIN" --disable-debug \
        --prefix=/usr/lib/jellyfin-ffmpeg --extra-version=Jellyfin --disable-doc --disable-ffplay --disable-shared \
        --disable-libxcb --disable-sdl2 --disable-xlib --enable-lto --enable-gpl --enable-version3 --enable-gmp \
        --enable-gnutls --enable-libdrm --enable-libass --enable-libfreetype --enable-libfribidi --enable-libfontconfig \
        --enable-libbluray --enable-libmp3lame --enable-libopus --enable-libtheora --enable-libvorbis --enable-libdav1d \
        --enable-libwebp --enable-libvpx --enable-libx264 --enable-libx265 --enable-libzimg --enable-small \
        --enable-nonfree --enable-libxvid --enable-libaom --enable-libfdk_aac --enable-vaapi \
        --enable-cuda-nvcc \
        --enable-hwaccel=h264_vaapi \
        --enable-hwaccel=hevc_vaapi --toolchain=hardened \
        --enable-hwaccel=h264_nvdec \
        --enable-hwaccel=hevc_nvdec \
        --enable-hwaccel=av1_nvdec \
        --enable-nvenc --enable-cuvid --enable-cuda \
        --extra-cflags="-I/usr/local/cuda/include" \
        --extra-ldflags="-L/usr/local/cuda/lib64" \
        --nvccflags="$NVCCFLAGS" || \
    { cat /usr/src/nvcc-wrapper.log || true; cat ffbuild/config.log; exit 1; } && \
    make -j$(nproc) && \
    make install && \
    make distclean && \
    rm -rf "${DIR}"

# ==============================================================
# 4️⃣ Builder image for the web UI
# ==============================================================
FROM nvidia/cuda:13.0.1-runtime-ubuntu22.04 AS builder-web

RUN apt-get update && apt-get install -y ca-certificates curl gnupg
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 
RUN apt-get install -y nodejs

WORKDIR /srv
RUN apt-get update && apt-get install -y --no-install-recommends git wget dos2unix && rm -rf /var/lib/apt/lists/*

ARG BRANCH=development
RUN REPO="https://github.com/Stremio/stremio-web.git"; if [ "$BRANCH" == "release" ];then git clone "$REPO" --depth 1 --branch $(git ls-remote --tags --refs $REPO | awk \'{print $2}\' | sort -V | tail -n1 | cut -d/ -f3); else git clone --depth 1 --branch "$BRANCH" https://github.com/Stremio/stremio-web.git; fi

WORKDIR /srv/stremio-web

COPY ./load_localStorage.js ./src/load_localStorage.js
RUN sed -i "/entry: {/a \        loader: './src/load_localStorage.js'," webpack.config.js

# Install dependencies and build the web project
RUN npm install -g pnpm
RUN pnpm install postcss@^8.4.38 --save-dev
RUN pnpm audit || true
RUN pnpm run build

RUN wget $(wget -O- https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt) && wget -mkEpnp -nH "https://app.strem.io/" "https://app.strem.io/worker.js" "https://app.strem.io/images/stremio.png" "https://app.strem.io/images/empty.png" -P build/shell/ || true
RUN find /srv/stremio-web -type f -not -name "*.png" -exec dos2unix {} + 

# ==============================================================
# 5️⃣ Main image
# ==============================================================
FROM nvidia/cuda:13.0.1-runtime-ubuntu22.04 AS final

RUN apt-get update && apt-get install -y ca-certificates curl gnupg
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 
RUN apt-get install -y nodejs

ARG VERSION=main
LABEL org.opencontainers.image.description="Stremio Web Player and Server"
LABEL org.opencontainers.image.licenses=MIT
LABEL version=${VERSION}

WORKDIR /srv/stremio-server
COPY --from=builder-web /srv/stremio-web/build ./build
COPY --from=builder-web /srv/stremio-web/server.js .
# Patch server.js to disable proxy streams, this is done at runtime in the original script
RUN sed -i '/self.allTranscodeProfiles = \[]/a \        self.proxyStreamsEnabled = false,' server.js

COPY ./ffprobe-wrapper.sh .
COPY ./ffmpeg-wrapper.sh .
COPY ./path-debug-wrapper.js .

COPY ./samples /srv/stremio-server/samples

RUN adduser --system --no-create-home --group nginx
RUN apt-get update && apt-get install -y --no-install-recommends nginx apache2-utils dos2unix && rm -rf /var/lib/apt/lists/*

COPY localStorage.json .

COPY ./nginx/ /etc/nginx/
COPY ./stremio-web-service-run.sh .
COPY ./certificate.js .
COPY ./restart_if_idle.sh .

# Change ownership of /srv/stremio-server to nginx user for write access
RUN chown -R nginx:nginx /srv/stremio-server

RUN dos2unix ./*.sh

RUN chmod +x ./*.sh

# Environment variables
ENV LIBRARY_MODE_NVIDIA=
ENV FFMPEG_BIN=
ENV FFPROBE_BIN=
ENV WEBUI_LOCATION=
ENV WEBUI_INTERNAL_PORT=
ENV OPEN=
ENV HLS_DEBUG=
ENV DEBUG=
ENV DEBUG_MIME=
ENV DEBUG_FD=
ENV FFMPEG_DEBUG=
ENV FFSPLIT_DEBUG=
ENV NODE_DEBUG=
ENV NODE_ENV=production
ENV HTTPS_CERT_ENDPOINT=
ENV DISABLE_CACHING=
ENV READABLE_STREAM=
ENV APP_PATH=
ENV NO_CORS=
ENV CASTING_DISABLED=
ENV IPADDRESS=
ENV DOMAIN=
ENV CERT_FILE=
ENV SERVER_URL=
ENV AUTO_SERVER_URL=0
ENV USERNAME=
ENV PASSWORD=

# Copy ffmpeg from the build stage
COPY --from=ffmpeg-build /usr/lib/jellyfin-ffmpeg /usr/lib/jellyfin-ffmpeg/
COPY --from=ffmpeg-build /usr/bin/ffmpeg /usr/bin/
COPY --from=ffmpeg-build /usr/bin/ffprobe /usr/bin/

# Add runtime libraries for ffmpeg
# Note: Some library versions might be specific to Ubuntu 22.04.
RUN RUNTIME_DEPS=" \
    libwebp7 \
    libwebpmux3 \
    libvorbis0a \
    libvorbisenc2 \
    libva-drm2 \
    libx265-199 \
    libx264-163 \
    libass9 \
    libopus0 \
    libgmpxx4ldbl \
    libmp3lame0 \
    libgnutls30 \
    libvpx7 \
    libtheora0 \
    libdrm2 \
    libbluray2 \
    libzimg2 \
    libdav1d5 \
    libaom3 \
    libxvidcore4 \
    libfdk-aac2 \
    libva2 \
    curl \
    procps \
    " && \
    apt-get update && \
    apt-get install -y --no-install-recommends $RUNTIME_DEPS && \
    rm -rf /var/lib/apt/lists/*

# Add architecture-specific libraries (for Intel Quick Sync Video)
RUN if [ "$(uname -m)" = "x86_64" ]; then \
    apt-get update && \
    apt-get install -y --no-install-recommends intel-media-va-driver-non-free mesa-va-drivers && \
    rm -rf /var/lib/apt/lists/*; \
  fi

VOLUME ["/root/.stremio-server"]

# Expose default ports
EXPOSE 8080

ENTRYPOINT []

CMD ["./stremio-web-service-run.sh"]