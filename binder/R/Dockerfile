FROM rocker/binder:latest

#USER root
RUN apt-get update && apt-get -y install cron
RUN apt-get update && apt-get -y install jags
RUN apt-get update && apt-get -y install libgd-dev
RUN apt-get update && apt-get -y install libnetcdf-dev

RUN sudo update-ca-certificates

#USER ${NB_USER}

RUN apt-get -y install python3 python3-pip

RUN install2.r devtools remotes reticulate

RUN R -e "remotes::install_github('cboettig/minioclient')"
RUN sleep 180
RUN R -e "remotes::install_github('eco4cast/stac4cast')"
RUN sleep 180
RUN R -e "remotes::install_github('eco4cast/EFIstandards')"
RUN sleep 180
RUN R -e "remotes::install_github('cboettig/aws.s3')"
RUN sleep 180
RUN R -e "remotes::install_github('eco4cast/score4cast')"
RUN sleep 180
RUN R -e "remotes::install_github('EcoForecast/ecoforecastR')"
RUN sleep 180
RUN R -e "remotes::install_github('eco4cast/neon4cast')"
RUN sleep 180
RUN R -e "remotes::install_github('cboettig/prov')"
RUN sleep 180
RUN R -e "remotes::install_github('eco4cast/read4cast')"
RUN sleep 180
RUN R -e "remotes::install_github('eco4cast/gefs4cast')"
RUN sleep 180
RUN R -e "remotes::install_github('mitchelloharawild/distributional', ref = 'bb0427e')"

RUN install2.r arrow renv rjags neonstore ISOweek RNetCDF fable fabletools forecast imputeTS duckdbfs gsheet

RUN install2.r ncdf4 scoringRules tidybayes tidync udunits2 bench contentid yaml RCurl here feasts future furrr jsonlite

#RUN R -e "reticulate::install_python(version = '3.9:latest', list = FALSE, force = FALSE)"

COPY cron.sh /etc/services.d/cron/run

