FROM eco4cast/rocker-neon4cast:latest

# Import GitHub Secret
ARG GITHUB_PAT
ENV GITHUB_PAT=$GITHUB_PAT

# Install required system packages
RUN apt-get update && apt-get install -y \
    python3-venv \
    python3-pip \
    curl \
    unzip

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && sudo ./aws/install \
    && rm awscliv2.zip

# Create a virtual environment
RUN python3 -m venv /opt/venv

# Upgrade pip in the virtual environment
RUN /opt/venv/bin/pip install --upgrade pip

# Install Python packages in the virtual environment
RUN /opt/venv/bin/pip install --no-cache-dir pandas pyarrow statsmodels boto3 requests matplotlib

# Set the PATH to use the virtual environment
ENV PATH="/opt/venv/bin:$PATH"

COPY cron.sh /etc/services.d/cron/run
