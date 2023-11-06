FROM buildpack-deps:jammy

# set bash as the default interpreter for the build with:
# -e: exits on error, so we can use colon as line separator
# -u: throw error on variable unset
# -o pipefail: exits on first command failed in pipe
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]


# RUN printf '%s' 'Acquire::http::Proxy::ports.ubuntu.com "http://aptcache.lan:3142";' | tee /etc/apt/apt.conf.d/proxy.conf

# build helpers
ARG DEBIANFRONTEND="noninteractive"
ARG APT_GET="apt-get"
ARG APT_GET_INSTALL="${APT_GET} install -yq --no-install-recommends"
ARG CLEAN_APT="${APT_GET} clean && ${APT_GET} autoclean"
ARG CURL="curl -fsSL"

RUN \
    ## apt \
    ${APT_GET} update; \
    # upgrade system \
    ${APT_GET} -yq upgrade; \
    # install add-apt-repository \
    ${APT_GET_INSTALL} software-properties-common; \
    ## apt repositories \
    # git \
    # add-apt-repository --no-update -y ppa:git-core/ppa; \
    # git-lfs \
    # ${CURL} https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | -E bash -; \
    # install apt packages \
    ${APT_GET_INSTALL} \
        shc \
        skopeo \
        git \
        # git-lfs \
        tree \
        jq \
        parallel \
        rsync \
        sshpass \
        python3-pip \
        python-is-python3 \
        openjdk-11-jdk-headless \
        shellcheck \
        zip \
        unzip \
        time \
        # required for docker in docker \
        iptables \
        xz-utils \
        # network \
        net-tools \
        iputils-ping \
        mtr-tiny \
        dnsutils \
        netcat \
        openssh-server \
        # docker pre-requisites \
        ca-certificates \
        curl \
        gnupg \
        # docker \
        docker.io \
        containerd \
        docker-buildx \
        docker-compose; \
    ${APT_GET} autoremove -yq; \
    ${CLEAN_APT};

COPY init_as_root.sh /
RUN shc -S -r -f /init_as_root.sh -o /init_as_root; \
    chown root:root /init_as_root; \
    chmod 4755 /init_as_root ; \
    rm /init_as_root.sh

COPY rootfs /
RUN update-ca-certificates

ENV NON_ROOT_USER=jenkins
ARG HOME="/home/${NON_ROOT_USER}"

ENV AGENT_WORKDIR="${HOME}/agent" \
    CI=true \
    # locale and encoding \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8" \
    ## Entrypoint related \
    # Fails if cont-init and fix-attrs fails \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    # Wait for dind before running CMD \
    S6_CMD_WAIT_FOR_SERVICES=1

# create non-root user
RUN group="${NON_ROOT_USER}"; \
    uid="1000"; \
    gid="${uid}"; \
    groupadd -g "${gid}" "${group}"; \
    useradd -l -c "Jenkins user" -d "${HOME}" -u "${uid}" -g "${gid}" -m "${NON_ROOT_USER}" -s /bin/bash -p ""; \
    # install sudo and locales\
    ${APT_GET} update; \
    ${APT_GET_INSTALL} \
        sudo \
        locales; \
    # clean apt cache \
    ${CLEAN_APT}; \
    # setup locale \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen; \
    locale-gen; \
    # setup sudo \
    usermod -aG sudo "${NON_ROOT_USER}"; \
    echo "${NON_ROOT_USER}  ALL=(ALL) NOPASSWD:ALL" | tee "/etc/sudoers.d/${NON_ROOT_USER}"; \
    # dismiss sudo welcome message \
    sudo -u "${NON_ROOT_USER}" sudo true


WORKDIR "${AGENT_WORKDIR}"

VOLUME "${AGENT_WORKDIR}"

RUN \
    # ensure jenkins-agent directory exists \
    mkdir -p "${AGENT_WORKDIR}"; \
    # setup docker \
    usermod -aG docker "${NON_ROOT_USER}"; \
    ## dind \
    # set up subuid/subgid so that "--userns-remap=default" works out-of-the-box \
    addgroup --system dockremap; \
    adduser --system --ingroup dockremap dockremap; \
    echo 'dockremap:165536:65536' | tee -a /etc/subuid; \
    echo 'dockremap:165536:65536' | tee -a /etc/subgid; \
    # install dind hack \
    # https://github.com/moby/moby/commits/master/hack/dind \
    # version="1f32e3c95d72a29b3eaacba156ed675dba976cb5"; \
    # sudo ${CURL} -o /usr/local/bin/dind "https://raw.githubusercontent.com/moby/moby/${version}/hack/dind"; \
    ${CURL} -o /usr/local/bin/dind "https://raw.githubusercontent.com/moby/moby/master/hack/dind"; \
    chmod +x /usr/local/bin/dind; \
    # install jenkins-agent \
    base_url="https://repo.jenkins-ci.org/public/org/jenkins-ci/main/remoting"; \
    version=$(curl -fsS ${base_url}/maven-metadata.xml | grep "<latest>.*</latest>" | sed -e "s#\(.*\)\(<latest>\)\(.*\)\(</latest>\)\(.*\)#\3#g"); \
    curl --create-dirs -fsSLo /usr/share/jenkins/agent.jar "${base_url}/${version}/remoting-${version}.jar"; \
    chmod 755 /usr/share/jenkins; \
    chmod +x /usr/share/jenkins/agent.jar; \
    ln -sf /usr/share/jenkins/agent.jar /usr/share/jenkins/slave.jar; \
    # install jenkins-agent wrapper from inbound-agent \
    version=$(basename "$(${CURL} -o /dev/null -w "%{url_effective}" https://github.com/jenkinsci/docker-inbound-agent/releases/latest)"); \
    ${CURL} -o /usr/local/bin/jenkins-agent "https://raw.githubusercontent.com/jenkinsci/docker-inbound-agent/${version}/jenkins-agent"; \
    chmod +x /usr/local/bin/jenkins-agent; \
    ln -sf /usr/local/bin/jenkins-agent /usr/local/bin/jenkins-slave; \
    ## miscellaneous \
    # install s6-overlay \
    ${CURL} -o /tmp/s6-overlay-noarch.tar.xz https://github.com/just-containers/s6-overlay/releases/latest/download/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    if [ "$(arch)" == "x86_64" ]; then \
        version="x86_64"; \
    elif [ "$(arch)" == "aarch64" ]; then \
         version="aarch64"; \
    fi; \
    ${CURL} -o /tmp/s6-overlay.tar.xz https://github.com/just-containers/s6-overlay/releases/latest/download/s6-overlay-${version}.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay.tar.xz; \
    unset version; \
    # fix sshd not starting \
    mkdir -p /run/sshd; \
    # install fixuid \
    if [ "$(arch)" == "x86_64" ]; then \
        version="amd64"; \
    elif [ "$(arch)" == "aarch64" ]; then \
         version="arm64"; \
    fi; \
    curl -fsSL https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-${version}.tar.gz | sudo tar -C /usr/local/bin -xzf -; \
    unset version; \
    chown root:root /usr/local/bin/fixuid;\
    chmod 4755 /usr/local/bin/fixuid; \
    mkdir -p /etc/fixuid; \
    printf '%s\n' "user: ${NON_ROOT_USER}" "group: ${NON_ROOT_USER}" "paths:" "  - /" "  - ${AGENT_WORKDIR}" | tee /etc/fixuid/config.yml

# use non-root user with sudo when needed
USER "${NON_ROOT_USER}:${NON_ROOT_USER}"

ENTRYPOINT [ "/entrypoint.sh" ]
CMD [ "bash" ]
