FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables iproute2 postgresql-client dnsutils procps bash && \
    rm -rf /var/lib/apt/lists/*
    
COPY switcher.sh /usr/local/bin/switcher.sh
RUN chmod +x /usr/local/bin/switcher.sh

ENTRYPOINT ["/usr/local/bin/switcher.sh"]