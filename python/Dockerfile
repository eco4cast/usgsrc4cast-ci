FROM eco4cast/rocker-neon4cast:latest

# Import GitHub Secret
ARG GITHUB_PAT
ENV GITHUB_PAT=$GITHUB_PAT

# install aws cli
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip
RUN sudo ./aws/install

# Install Python and pip
RUN apt-get update && apt-get -y install python3 python3-pip

# Install Python packages
RUN pip install --no-cache-dir pandas pyarrow statsmodels boto3 requests matplotlib


COPY cron.sh /etc/services.d/cron/run
