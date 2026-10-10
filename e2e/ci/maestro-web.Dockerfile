# Maestro + Chromium for running the web suite where Maestro cannot manage its
# own browser: arm64 Linux (Selenium Manager has no build for it), or any host
# where you would rather not install a browser.
#
# Built and used automatically by `e2e/run.sh web` on arm64 Linux, or anywhere
# with E2E_MAESTRO_WEB_DOCKER=1. Debian, because its chromium and
# chromium-driver are real packages (Ubuntu's are snaps, which webdriver
# cannot drive reliably).
FROM debian:bookworm-slim

ARG MAESTRO_VERSION=2.11.0

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl unzip openjdk-17-jre-headless chromium chromium-driver fonts-liberation \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/maestro.zip \
      "https://github.com/mobile-dev-inc/maestro/releases/download/cli-${MAESTRO_VERSION}/maestro.zip" \
 && unzip -q /tmp/maestro.zip -d /opt \
 && rm /tmp/maestro.zip

# Use the system browser and driver instead of Selenium Manager.
ENV PATH=/opt/maestro/bin:$PATH \
    SE_CHROMEDRIVER=/usr/bin/chromedriver \
    SE_BROWSER_PATH=/usr/bin/chromium \
    MAESTRO_CLI_NO_ANALYTICS=1 \
    MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true \
    HOME=/tmp/home \
    JAVA_TOOL_OPTIONS=-Duser.home=/tmp/home

# Chromium refuses to start as root, and the run directory is mounted from the
# host, so the container runs as the invoking user (see run_maestro). That
# user has no passwd entry, so Java is told where home is explicitly.
RUN mkdir -p /tmp/home && chmod 1777 /tmp/home
