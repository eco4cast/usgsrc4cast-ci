FROM eco4cast/rocker-neon4cast:latest

# Import GitHub Secret
ARG GITHUB_PAT
ENV GITHUB_PAT=$GITHUB_PAT

# Install Python and pip
RUN apt-get update && apt-get -y install python3 python3-pip

# Install Python packages
RUN pip install --no-cache-dir pandas pyarrow statsmodels boto3 requests


COPY cron.sh /etc/services.d/cron/run
