import pandas as pd
import os
import subprocess

def submit(forecast_file=None,
           project_id=None,
           metadata=None,
           ask=True,
           s3_region="submit",
           s3_endpoint="ecoforecast.org"):
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
    None
    """
    if forecast_file is None:
        raise ValueError("Path to forecast_file must be provided")
        
    if project_id is None:
        raise ValueError("project_id must be provided")
        
    if os.path.exists(os.path.expanduser("~/.aws")):
        print("Detected existing AWS credentials file in ~/.aws. Consider renaming these so that automated upload will work.")
    
    print("validating that file matches required standards")
    go = forecast_output_validator(forecast_file)

    if not go:
        print("Forecast was not in a valid format and was not submitted.")
        print("First, try reinstalling neon4cast (remotes::install_github('eco4cast\\neon4cast'), sourcing usgsrc4cast-specific functions (https://projects.ecoforecast.org/usgsrc4cast-ci/instructions.html#uploading-forecast), restarting Python, and trying again.")
        print("Second, see https://projects.ecoforecast.org/usgsrc4cast-ci/instructions.html for more information on the file format.")
        return

    check_model_id = False
    if check_model_id:
        print("Checking if model_id is registered")
        registered_model_id = pd.read_csv("https://docs.google.com/spreadsheets/d/1f177dpaxLzc4UuQ4_SJV9JWIbQPlilVnEztyvZE6aSU/export?format=csv")

        registered_project_id = registered_model_id['What forecasting challenge are you registering for?']
        registered_model_id = registered_model_id['model_id']

        registered_model_project_id = registered_project_id + "-" + registered_model_id

        df = pd.read_csv(forecast_file)
        model_id = df['model_id'][0]
        model_project_id = project_id + "-" + model_id

        if "example" in model_id:
            print("You are submitting a forecast with 'example' in the model_id. As an example forecast, it will be processed but not used in future analyses.")
            print("No registration is required to submit an example forecast.")
            print("If you want your forecast to be retained, please select a different model_id that does not contain 'example' and register your model id at https://forms.gle/kg2Vkpho9BoMXSy57")

        if model_project_id not in registered_model_project_id and "example" not in model_id:
            print(f"Checking if model_id is already used in submissions for {project_id}")

            submitted_model_ids = pd.read_csv("https://sdsc.osn.xsede.org/bio230014-bucket01/challenges/inventory/model_id/model_id-project_id-inventory.csv")
            submitted_project_model_id = submitted_model_ids['project_id'] + "-" + submitted_model_ids['model_id']

            if model_project_id in submitted_project_model_id:
                raise ValueError(f"Your model_id ({model_id}) has not been registered yet but is already used in other submissions. Please use and register another model_id.\nRegister at https://forms.gle/kg2Vkpho9BoMXSy57\nIf you want to submit without registering, include the word 'example' in your model_id. As an example forecast, it will be processed but not used in future analyses.")
            else:
                raise ValueError(f"Your model_id ({model_id}) has not been registered.\nRegister at https://forms.gle/kg2Vkpho9BoMXSy57\nIf you want to submit without registering, include the word 'example' in your model_id. As an example forecast, it will be processed but not used in future analyses.")

    if go and ask:
        go = input("Forecast file is valid, ready to submit? (yes/no): ").strip().lower() == "yes"

    # check if project_id is valid
    check_project_id = False
    if check_project_id:
        submitted_model_ids = pd.read_csv("https://sdsc.osn.xsede.org/bio230014-bucket01/challenges/inventory/model_id/model_id-project_id-inventory.csv")
        all_project_ids = submitted_model_ids['project_id'].unique()
        if project_id not in all_project_ids:
            raise ValueError(f"The project_id you supplied, {project_id}, is not in the list of current forecast challenge project_ids [{', '.join(all_project_ids)}]")

    # GENERALIZATION: Here are specific AWS INFO
    if go:
        # submit with AWS command line interface 
        submit_forecast_with_aws_cli(forecast_file = forecast_file, 
                                     project_id = project_id)
    else:
        print("Forecast was not submitted to server. Try again, then contact the Challenge organizers.")


def submit_forecast_with_aws_cli(forecast_file, 
                                 project_id):
    """
    Submit forecast to EFI forecast challenge using AWS CLI with no-sign-request.

    Parameters:
    forecast_file (str): The path to the forecast file to submit.
    project_id (str): The forecast challenge project_id to submit to.
    
    Returns:
    None
    """
    check_aws_cli()
        
    try:
        # Construct the command
        command = [
            "aws", "s3", "cp",
            forecast_file,
            f"s3://submissions/{project_id}/{os.path.basename(forecast_file)}",
            "--endpoint-url", "https://submit.ecoforecast.org/",
            "--region", "data",
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