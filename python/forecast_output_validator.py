import pandas as pd

def lexists(df, name):
    """
    Check if the given column name(s) exist in the dataframe.
    
    Parameters:
    df (pd.DataFrame): The dataframe to check.
    name (str or list of str): The column name(s) to check for.
    
    Returns:
    bool: True if the column name(s) exist, False otherwise.
    """
    if isinstance(name, str):
        name = [name]
    return all(col in df.columns for col in name)

def forecast_output_validator(forecast_file):
    """
    Validate forecast file.
    
    Parameters:
    forecast_file (str): Forecast CSV or CSV.GZ file.
    
    Returns:
    bool: True if the forecast file is valid, False otherwise.
    """
    file_in = forecast_file
    valid = True

    print(file_in)

    if any(file_in.endswith(ext) for ext in [".csv", ".csv.gz"]):
        # if file is csv or csv.gz file
        out = pd.read_csv(file_in)

        if lexists(out, "model_id"):
            print("file has model_id column")
        else:
            print("file missing model_id column")
            valid = False

        if "variable" in out.columns and "prediction" in out.columns:
            print("forecasted variables found correct variable + prediction column")
        else:
            print("missing the variable and prediction columns")
            valid = False

        if lexists(out, "ensemble"):
            print("ensemble dimension should be named parameter")
            valid = False
        elif lexists(out, "family"):
            if lexists(out, "parameter"):
                print("file has correct family and parameter columns")
            else:
                print("file does not have parameter column")
                valid = False
        else:
            print("file does not have ensemble or family and/or parameter column")
            valid = False

        if lexists(out, "site_id"):
            print("file has site_id column")
        else:
            print("file missing site_id column")
            valid = False

        if lexists(out, "datetime"):
            print("file has datetime column")
            if not "-" in out["datetime"].iloc[0]:
                print("datetime column format is not in the correct YYYY-MM-DD format")
                valid = False
            else:
                print("file has correct datetime column")

        else:
            print("file missing datetime column")
            valid = False

        if lexists(out, "duration"):
            print("file has duration column")
        else:
            print("file missing duration column (values for the column: daily = P1D, 30min = PT30M)")
            valid = False

        if lexists(out, "project_id"):
            print("file has project_id column")
        else:
            print("file missing project_id column (use the challenge you're submitting to as the project_id")
            valid = False

        if lexists(out, "reference_datetime"):
            print("file has reference_datetime column")
        elif lexists(out, "start_time"):
            print("file start_time column should be named reference_datetime. We are converting it during processing but please update your submission format")
        else:
            print("file missing reference_datetime column")
            valid = False
    else:
        print("incorrect file extension (csv or csv.gz are accepted)")
        valid = False

    if not valid:
        print("Forecast file is not valid. The following link provides information about the format:\nhttps://projects.ecoforecast.org/neon4cast-ci/instructions.html#forecast-file-format")
    else:
        print("Forecast format is valid")
    
    return valid

