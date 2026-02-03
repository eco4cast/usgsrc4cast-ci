import os
import subprocess

from forecast_output_validator import forecast_output_validator

def submit(forecast_file=None,
           project_id=None,
           metadata=None,
           ask=True,
           s3_region="s3-west",
           s3_endpoint="nrp-nautilus.io"):
    """
    Submit forecast to EFI-USGS forecast challenge.

    Parameters:
    forecast_file (str): The path to the forecast file to submit.
    project_id (str): The forecast challenge project_id to submit to.
    metadata (str): Path to metadata file.
    ask (bool): Should we prompt for a go before submission?
    s3_region (str): Subdomain (leave as is for EFI challenge).
    s3_endpoint (str): Root domain (leave as is for EFI challenge).

    Returns:
    bool: True if submission succeeded, False otherwise.
    """
    if forecast_file is None:
        raise ValueError("Path to forecast_file must be provided")

    if project_id is None:
        raise ValueError("project_id must be provided")

    ## Temporarily isolate from any existing AWS credentials
    aws_vars = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN", "AWS_DEFAULT_PROFILE", "AWS_PROFILE"]
    saved_env = {v: os.environ.pop(v) for v in aws_vars if v in os.environ}

    aws_dir = os.path.expanduser("~/.aws")
    aws_bak = os.path.expanduser("~/.aws.bak")
    renamed_aws = False
    if os.path.exists(aws_dir):
        os.rename(aws_dir, aws_bak)
        renamed_aws = True

    try:
        print("validating that file matches required standards")
        go = forecast_output_validator(forecast_file)

        if not go:
            print("Forecast was not in a valid format and was not submitted.")
            print("First, try sourcing usgsrc4cast-specific functions (https://projects.ecoforecast.org/usgsrc4cast-ci/instructions.html#uploading-forecast), restarting Python, and trying again.")
            print("Second, see https://projects.ecoforecast.org/usgsrc4cast-ci/instructions.html for more information on the file format.")
            return False

        if go and ask:
            go = input("Forecast file is valid, ready to submit? (yes/no): ").strip().lower() == "yes"

        # GENERALIZATION: Here are specific AWS INFO
        if go:
            # submit with AWS command line interface
            submit_forecast_with_aws_cli(forecast_file=forecast_file,
                                         project_id=project_id,
                                         s3_region=s3_region,
                                         s3_endpoint=s3_endpoint)
            return True
        else:
            print("Forecast was not submitted to server. Try again, then contact the Challenge organizers.")
            return False
    finally:
        # Restore environment variables
        for v, val in saved_env.items():
            os.environ[v] = val
        # Restore ~/.aws directory
        if renamed_aws and os.path.exists(aws_bak):
            os.rename(aws_bak, aws_dir)


def submit_forecast_with_aws_cli(forecast_file,
                                 project_id,
                                 s3_region="s3-west",
                                 s3_endpoint="nrp-nautilus.io"):
    """
    Submit forecast to EFI forecast challenge using AWS CLI with no-sign-request.

    Parameters:
    forecast_file (str): The path to the forecast file to submit.
    project_id (str): The forecast challenge project_id to submit to.
    s3_region (str): S3 region subdomain.
    s3_endpoint (str): S3 root domain.

    Returns:
    None
    """
    check_aws_cli()

    endpoint_url = f"https://{s3_region}.{s3_endpoint}"

    try:
        # Construct the command
        command = [
            "aws", "s3", "cp",
            forecast_file,
            f"s3://submissions/{project_id}/{os.path.basename(forecast_file)}",
            "--endpoint-url", endpoint_url,
            "--region", s3_region,
            "--no-sign-request",
            "--no-verify-ssl"
        ]

        # Run the command
        result = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Print the output
        print(result.stdout.decode())
        print("Thank you for submitting!")
    except subprocess.CalledProcessError as e:
        print("Forecast was not successfully submitted to server. Try again, then contact the Challenge organizers.")
        print(e.stderr.decode())


def check_aws_cli():
    try:
        result = subprocess.run(["aws", "--version"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        print(result.stdout.decode())
    except subprocess.CalledProcessError as e:
        print("AWS CLI is not installed or not found in PATH.")
        print(e.stderr.decode())
        raise
