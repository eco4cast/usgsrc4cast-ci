## MODEL level functions

generate_authors <- function(metadata_table, index){

  x <- list(list('url' = 'pending',
                 'name' = 'pending',
                 'roles' = list("producer",
                                "processor",
                                "licensor"))
  )
}

generate_model_assets <- function(m_vars, m_duration, aws_path){

  metadata_json_asset <- list(
    "1"= list(
      'type'= 'application/json',
      'title' = 'Model Metadata',
      'href' = paste0("https://", config$endpoint,"/",
                      config$model_metadata_bucket,"/",
                      "project_id=",config$project_id, "/",
                      m,".json"),
      'description' = paste0("Use `jsonlite::fromJSON()` to download the model metadata JSON file. This R code will return metadata provided during the model registration.
      \n\n### R\n\n```{r}\n# Use code below\n\nmodel_metadata <- jsonlite::fromJSON(",paste0('"','https://', config$endpoint,'/', config$model_metadata_bucket,'/', 'project_id=', config$project_id, '/', m,'.json"'),")\n\n")
    )
  )

  iterator_list <- 1:length(m_vars)

  model_data_assets <- purrr::map(iterator_list, function(i)
    list(
      'type'= 'application/x-parquet',
      'title' = paste0('Database Access for ',m_vars[i],' ', m_duration[i]),
      'href' = paste0("s3://anonymous@",
                      aws_path,
                      "/parquet/duration=P1D/variable=", m_vars[i],
                      "/model_id=", m,
                      "?endpoint_override=",config$endpoint),
      'description' = paste0("Use `arrow` for remote access to the database. This R code will return results for this variable and model combination.\n\n### R\n\n```{r}\n# Use code below\n\nall_results <- arrow::open_dataset(",paste0("s3://anonymous@",
                                                                                                                                                                                                                                                                       aws_path,
                                                                                                                                                                                                                                                                       "/parquet/duration=P1D/variable=", m_vars[i],
                                                                                                                                                                                                                                                                       "/model_id=", m,
                                                                                                                                                                                                                                                       "?endpoint_override=",config$endpoint),")\ndf <- all_results |> dplyr::collect()\n\n```
       \n\nYou can use dplyr operations before calling `dplyr::collect()` to `summarise`, `select` columns, and/or `filter` rows prior to pulling the data into a local `data.frame`. Reducing the data that is pulled locally will speed up the data download speed and reduce your memory usage.\n\n\n")
    )
  )

  model_assets <- c(metadata_json_asset, model_data_assets)

  return(model_assets)
}


build_model <- function(model_id,
                        theme_id,
                        team_name,
                        model_description,
                        start_date,
                        end_date,
                        use_metadata,
                        var_values,
                        duration_names,
                        site_values,
                        model_documentation,
                        destination_path,
                        description_path,
                        aws_download_path,
                        theme_title,
                        collection_name,
                        thumbnail_image_name,
                        table_schema,
                        table_description) {


  preset_keywords <- list("Forecasting", config$project_id)
  variables_reformat <- paste(var_values, collapse = ", ")
  site_reformat <- paste(site_values, collapse = ", ")

  aws_asset_link <- paste0("s3://anonymous@",
                           aws_download_path,
                           "/model_id=", model_id,
                           "?endpoint_override=",config$endpoint)

  aws_asset_description <- paste0("Use `arrow` for remote access to the database. This R code will return results for forecasts of the variable by the specific model .\n\n### R\n\n```{r}\n# Use code below\n\nall_results <- arrow::open_dataset(",aws_asset_link,")\ndf <- all_results |> dplyr::collect()\n\n```
       \n\nYou can use dplyr operations before calling `dplyr::collect()` to `summarise`, `select` columns, and/or `filter` rows prior to pulling the data into a local `data.frame`. Reducing the data that is pulled locally will speed up the data download speed and reduce your memory usage.\n\n\n")

  meta <- list(
    "stac_version"= "1.0.0",
    "stac_extensions"= list('https://stac-extensions.github.io/table/v1.2.0/schema.json'),
    "type"= "Feature",
    "id"= model_id,
    "bbox"=
      list(list(as.numeric(catalog_config$bbox$min_lon),
           as.numeric(catalog_config$bbox$max_lat),
           as.numeric(catalog_config$bbox$max_lon),
           as.numeric(catalog_config$bbox$max_lat))),
    "geometry"= list(
      "type"= catalog_config$site_type,
      "coordinates"=  get_site_coords(sites = site_values)
    ),
    "properties"= list(
      #'description' = model_description,
      "description" = glue::glue('

    model info: {model_description}

    Sites: {site_reformat}

    Variables: {variables_reformat}
'),
      "start_datetime" = start_date,
      "end_datetime" = end_date,
      "providers"= c(generate_authors(metadata_table = model_documentation),list(
        list(
          "url"= catalog_config$host_url,
          "name"= catalog_config$host_name,
          "roles"= list(
            "host"
          )
        )
      )
      ),
      "license"= "CC0-1.0",
      "keywords"= c(preset_keywords, variables_reformat),
      #"table:columns" = stac4cast::build_table_columns_full_bucket(table_schema, table_description)
      "table:columns" = build_table_columns_full_bucket(table_schema, table_description)
    ),
    "collection"= collection_name,
    "links"= list(
      list(
        "rel"= "collection",
        'href' = '../collection.json',
        "type"= "application/json",
        "title"= theme_title
      ),
      list(
        "rel"= "root",
        'href' = '../../../catalog.json',
        "type"= "application/json",
        "title"= "Forecast Catalog"
      ),
      list(
        "rel"= "parent",
        'href' = '../collection.json',
        "type"= "application/json",
        "title"= theme_title
      ),
      list(
        "rel"= "self",
        "href" = paste0(model_id,'.json'),
        "type"= "application/json",
        "title"= "Model Forecast"
      )),
    "assets"= generate_model_assets(var_values, duration_names, aws_download_path)#,
    #pull_images(theme_id,model_id,thumbnail_image_name)
  )


  dest <- destination_path
  json <- file.path(dest, paste0(model_id, ".json"))

  jsonlite::write_json(meta,
                       json,
                       pretty=TRUE,
                       auto_unbox=TRUE)
  stac4cast::stac_validate(json)

  rm(meta)
}

get_grouping <- function(inv_bucket,
                         theme,
                         collapse=TRUE) {

  groups <- duckdbfs::open_dataset(glue::glue("s3://anonymous@{inv_bucket}/catalog?endpoint_override=",config$endpoint)) |>
    dplyr::filter(...1 == "parquet", ...2 == {theme}) |>
    dplyr::select(model_id = ...3, reference_datetime = ...4, date = ...5) |>
    dplyr::mutate(model_id = gsub("model_id=", "", model_id),
                  reference_datetime =
                    gsub("reference_datetime=", "", reference_datetime),
                  date = gsub("date=", "", date)) |>
    dplyr::collect()

}

# DONT USE THIS FUNCTION ANYMORE -- WAS USED FOR ORIGINAL NEON4CAST STAC CODE (KEEPING THIS FOR REFERENCE BUT DELETE EVENTUALLY)
# generate_vars_sites <- function(m_id, theme){
#
#   # if (m_id %in%  c('GLEON_JRabaey_temp_physics','GLEON_lm_lag_1day','GLEON_physics','USGSHABs1','air2waterSat_2','fARIMA')){
#   #   output_info <- c('pending','pending')
#   # } else{
#
#   # do this for each theme / model
#   # info_df <- arrow::open_dataset(info_extract$path(glue::glue("{theme}/model_id={m_id}/"))) |>
#   #   #filter(reference_datetime == "2023-06-18")|> #just grab one EM to limit processing
#   #   collect()
#   #
#   info_df <- duckdbfs::open_dataset(glue::glue("s3://anonymous@neon4cast-scores/parquet/{theme}/
#                                                model_id={model_id}/reference_datetime={reference_datetime}?endpoint_override=sdsc.osn.xsede.org")) |>
#     collect()
#
#   if ('siteID' %in% names(info_df)){
#     info_df <- info_df |>
#       rename(site_id = siteID)
#   }
#
#   vars_vector <- sort(unique(info_df$variable))
#   sites_vector <- sort(unique(info_df$site_id))
#
#   vars_list <- as.list(sort(unique(info_df$variable)))
#   sites_list <- as.list(sort(unique(info_df$site_id)))
#
#   # output_vectors <- c(paste(vars_vector, collapse = ', '),
#   #                  paste(sites_vector, collapse = ', '))
#
#   output_list <- list(vars_list,sites_list)
#
#   full_object <- list(vars_vector, sites_vector, output_list)
#
#   return(full_object)
# }


## FORECAST LEVEL FUNCTIONS
generate_model_items <- function(model_list){

  x <- purrr::map(model_list, function(i)
    list(
      "rel" = 'item',
      'type'= 'application/json',
      'href' = paste0('model_items/',i,'.json'))
  )

  return(x)
}

pull_images <- function(theme, m_id, image_name){

  info_df <- arrow::open_dataset(info_extract$path(glue::glue("{theme}/model_id={m_id}/"))) |>
    collect()

  sites_vector <- sort(unique(info_df$site_id))

  base_path <- catalog_config$base_image_path

  image_assets <- purrr::map(sites_vector, function(i)
    #url_validator <- Rcurl::url.exists(file.path(base_path,theme,m_id,i,image_name))
    list(
      "href"= file.path(base_path,theme,m_id,i,image_name),
      "type"= "image/png",
      "title"= paste0('Latest Results for ', i),
      "description"= 'Image from s3 storage',
      "roles" = list('thumbnail')
    )
  )

  ## check if image rendered successfully on bucket. If not remove from assets
  item_remove <- c()

  if (image_name == 'latest_scores.png'){
    for (item in seq.int(1:length(image_assets))){
      url_validator = RCurl::url.exists(image_assets[[item]]$href)
      if(url_validator == FALSE){
        print(paste0('Removing ', image_assets[[item]]$title))
        item_remove <- append(item_remove,item)
      }
    }
    if (length(item_remove) > 0){
      image_assets <- image_assets[-item_remove]
    }
  }

  return(image_assets)

}


get_site_coords <- function(site_metadata, sites){

  site_df <- read_csv(site_metadata)

  # site_df <- data.frame(site_id = c('fcre', 'bvre', 'ccre'),
  #                       site_lon = c(-79.837217, -79.815936, -79.95856),
  #                       site_lat = c(37.303153, 37.312909, 37.370259))

  site_lat_lon <- lapply(sites, function(i) c(site_df$latitude[which(site_df[,2] == i)], site_df$longtitude[which(site_df[,2] == i)]))

  return(site_lat_lon)
}


generate_group_values <- function(group_values){

  x <- purrr::map(group_values, function(i)
    list(
      "rel" = "child",
      "type" = "application/json",
      "href" = paste0(i,"/collection.json"),
      "title" = i)
  )

  return(x)
}


build_forecast_scores <- function(table_schema,
                                  theme_id,
                                  table_description,
                                  start_date,
                                  end_date,
                                  id_value,
                                  description_string,
                                  about_string,
                                  about_title,
                                  theme_title,
                                  model_documentation,
                                  destination_path,
                                  aws_download_path,
                                  link_items,
                                  thumbnail_link,
                                  thumbnail_title
){

  aws_asset_link <- paste0("s3://anonymous@",
                           aws_download_path,
                           #"/model_id=", model_id,
                           "?endpoint_override=",config$endpoint)

  aws_asset_description <-   aws_asset_description <- paste0("Use `arrow` for remote access to the database. This R code will return results for the VERA Forecasting Challenge.\n\n### R\n\n```{r}\n# Use code below\n\nall_results <- arrow::open_dataset(",aws_asset_link,")\ndf <- all_results |> dplyr::collect()\n\n```
       \n\nYou can use dplyr operations before calling `dplyr::collect()` to `summarise`, `select` columns, and/or `filter` rows prior to pulling the data into a local `data.frame`. Reducing the data that is pulled locally will speed up the data download speed and reduce your memory usage.\n\n\n")
  forecast_score <- list(
    "id" = id_value,
    "description" = description_string,
    "stac_version"= "1.0.0",
    "license"= "CC0-1.0",
    "stac_extensions"= list("https://stac-extensions.github.io/scientific/v1.0.0/schema.json",
                            "https://stac-extensions.github.io/item-assets/v1.0.0/schema.json",
                            "https://stac-extensions.github.io/table/v1.2.0/schema.json"),
    'type' = 'Collection',
    'links' = c(link_items, #generate_model_items()
                list(
                  list(
                    "rel" = "child",
                    "type" = "application/json",
                    "href" = "models/collection.json",
                    "title" = "group item"
                  ),
                  list(
                    "rel" = "parent",
                    "type"= "application/json",
                    "href" = '../catalog.json'
                  ),
                  list(
                    "rel" = "root",
                    "type" = "application/json",
                    "href" = '../catalog.json'
                  ),
                  list(
                    "rel" = "self",
                    "type" = "application/json",
                    "href" = 'collection.json'
                  ),
                  list(
                    "rel" = "cite-as",
                    "href" = catalog_config$citation_doi
                  ),
                  list(
                    "rel" = "about",
                    "href" = about_string,
                    "type" = "text/html",
                    "title" = about_title
                  ),
                  list(
                    "rel" = "describedby",
                    "href" = catalog_config$dashboard_url,
                    "title" = catalog_config$dashboard_title,
                    "type" = "text/html"
                  )
                )),
    "title" = theme_title,
    "extent" = list(
      "spatial" = list(
        'bbox' = list(list(as.numeric(catalog_config$bbox$min_lon),
                      as.numeric(catalog_config$bbox$max_lat),
                      as.numeric(catalog_config$bbox$max_lon),
                      as.numeric(catalog_config$bbox$max_lat)))),
      "temporal" = list(
        'interval' = list(list(
          paste0(start_date,"T00:00:00Z"),
          paste0(end_date,"T00:00:00Z"))
        ))
    ),
    #"table:columns" = stac4cast::build_table_columns_full_bucket(table_schema, table_description),
    "table:columns" = build_table_columns_full_bucket(table_schema, table_description),

    'assets' = list(
      # 'data' = list(
      #   "href"= model_documentation,
      #   "type"= "text/csv",
      #   "roles" = list('data'),
      #   "title"= "NEON Field Site Metadata",
      #   "description"= readr::read_file(model_metadata_path)
      # ),
      'data' = list(
        "href" = aws_asset_link,
        "type"= "application/x-parquet",
        "title"= 'Database Access',
        "roles" = list('data'),
        "description"= aws_asset_description
      ),
      'thumbnail' = list(
        "href"= thumbnail_link,
        "type"= "image/JPEG",
        "roles" = list('thumbnail'),
        "title"= thumbnail_title
      )
    )
  )


  dest <- destination_path
  json <- file.path(dest, "collection.json")

  jsonlite::write_json(forecast_score,
                       json,
                       pretty=TRUE,
                       auto_unbox=TRUE)
  stac4cast::stac_validate(json)
}


generate_group_variable_items <- function(variables){


  var_values <- variables

  x <- purrr::map(var_values, function(i)
    list(
      "rel" = 'child',
      'type'= 'application/json',
      'href' = paste0(i,'/collection.json'))
  )

  return(x)
}

generate_variable_model_items <- function(model_list){


  #var_values <- variables

  x <- purrr::map(model_list, function(i)
    list(
      "rel" = 'item',
      'type'= 'application/json',
      'href' = paste0('../../models/model_items/',i,'.json'))
  )

  return(x)
}

build_group_variables <- function(table_schema,
                                  theme_id,
                                  table_description,
                                  start_date,
                                  end_date,
                                  id_value,
                                  description_string,
                                  about_string,
                                  about_title,
                                  theme_title,
                                  destination_path,
                                  aws_download_path,
                                  group_var_items
){

  aws_asset_link <-  paste0("s3://anonymous@",
                     aws_download_path,
                     #"/model_id=", model_id,
                     "?endpoint_override=",config$endpoint)

  aws_asset_description <-   aws_asset_description <- paste0("Use `arrow` for remote access to the database. This R code will return results for the NEON Ecological Forecasting Aquatics theme.\n\n### R\n\n```{r}\n# Use code below\n\nall_results <- arrow::open_dataset(",aws_asset_link,")\ndf <- all_results |> dplyr::collect()\n\n```
       \n\nYou can use dplyr operations before calling `dplyr::collect()` to `summarise`, `select` columns, and/or `filter` rows prior to pulling the data into a local `data.frame`. Reducing the data that is pulled locally will speed up the data download speed and reduce your memory usage.\n\n\n")
  forecast_score <- list(
    "id" = id_value,
    "description" = description_string,
    "stac_version"= "1.0.0",
    "license"= "CC0-1.0",
    "stac_extensions"= list("https://stac-extensions.github.io/scientific/v1.0.0/schema.json",
                            "https://stac-extensions.github.io/item-assets/v1.0.0/schema.json",
                            "https://stac-extensions.github.io/table/v1.2.0/schema.json"),
    'type' = 'Collection',
    'links' = c(group_var_items,#generate_group_variable_items(variables = group_var_values)
                list(
                  list(
                    "rel" = "parent",
                    "type"= "application/json",
                    "href" = '../collection.json'
                  ),
                  list(
                    "rel" = "root",
                    "type" = "application/json",
                    "href" = '../collection.json'
                  ),
                  list(
                    "rel" = "self",
                    "type" = "application/json",
                    "href" = 'collection.json'
                  ),
                  list(
                    "rel" = "cite-as",
                    "href" = "https://doi.org/10.1002/fee.2616"
                  ),
                  list(
                    "rel" = "about",
                    "href" = about_string,
                    "type" = "text/html",
                    "title" = about_title
                  ),
                  list(
                    "rel" = "describedby",
                    "href" = "https://ltreb-reservoirs.github.io/vera4cast/", # TODO: update this to something?
                    "title" = "EFI-USGS Forecast Challenge Dashboard",
                    "type" = "text/html"
                  )
                )),
    "title" = theme_title,
    "extent" = list(
      "spatial" = list(
        'bbox' = list(list(as.numeric(catalog_config$bbox$min_lon),
                      as.numeric(catalog_config$bbox$max_lat),
                      as.numeric(catalog_config$bbox$max_lon),
                      as.numeric(catalog_config$bbox$max_lat)))),
      "temporal" = list(
        'interval' = list(list(
          paste0(start_date,"T00:00:00Z"),
          paste0(end_date,"T00:00:00Z"))
        ))
    ),
    #"table:columns" = stac4cast::build_table_columns_full_bucket(table_schema, table_description),
    "table:columns" = build_table_columns_full_bucket(table_schema, table_description),
    'assets' = list(
      'data' = list(
        "href" = aws_asset_link,
        "type"= "application/x-parquet",
        "title"= 'Database Access',
        "roles" = list('data'),
        "description"= aws_asset_description
      )
    )
  )


  dest <- destination_path
  json <- file.path(dest, 'collection.json')

  jsonlite::write_json(forecast_score,
                       json,
                       pretty=TRUE,
                       auto_unbox=TRUE)
  stac4cast::stac_validate(json)
}

# build_theme <- function(start_date,end_date, id_value, theme_description, theme_title, destination_path, thumbnail_link, thumbnail_title){
#
#   theme <- list(
#     "id" = id_value,
#     "type" = "Collection",
#     "links" = list(
#       list(
#         "rel" = "child",
#         "type" = "application/json",
#         "href" = 'forecasts/collection.json',
#         "title" = 'forecast item'
#       ),
#       list(
#         "rel" = "child",
#         "type" = "application/json",
#         "href" = 'scores/collection.json',
#         "title" = 'scores item'
#       ),
#       list(
#         "rel"= "parent",
#         "type"= "application/json",
#         "href"= "../catalog.json",
#         "title" = 'parent'
#       ),
#       list(
#         "rel"= "root",
#         "type"= "application/json",
#         "href"= "../catalog.json",
#         "title" = 'root'
#       ),
#       list(
#         "rel"= "self",
#         "type"= "application/json",
#         "href" = 'collection.json',
#         "title" = 'self'
#       ),
#       list(
#         "rel" ="cite-as",
#         "href"= catalog_config$citation_link,
#         "title" = "citation"
#       ),
#       list(
#         "rel"= "about",
#         "href"= catalog_config$about_string,
#         "type"= "text/html",
#         "title"= catalog_config$about_title
#       ),
#       list(
#         "rel"= "describedby",
#         "href"= catalog_config$about_string,
#         "title"= catalog_config$about_title,
#         "type"= "text/html"
#       )
#     ),
#     "title"= theme_title,
#     'assets' = list(
#       'thumbnail' = list(
#         "href"= thumbnail_link,
#         "type"= "image/JPEG",
#         "roles" = list('thumbnail'),
#         "title"= thumbnail_title
#       )
#     ),
#     "extent" = list(
#       "spatial" = list(
#         'bbox' = list(list(as.numeric(catalog_config$bbox$min_lon),
#                       as.numeric(catalog_config$bbox$max_lat),
#                       as.numeric(catalog_config$bbox$max_lon),
#                       as.numeric(catalog_config$bbox$max_lat)))
#       ),
#       "temporal" = list(
#         'interval' = list(list(
#           paste0(start_date,'T00:00:00Z'),
#           paste0(end_date,'T00:00:00Z'))
#         ))
#     ),
#     "license" = "CC0-1.0",
#     "keywords" = list(
#       "Forecasting",
#       "Data",
#       "Ecology"
#     ),
#     "providers" = list(
#       list(
#         "url"= catalog_config$host_url,
#         "name"= catalog_config$host_name,
#         "roles" = list(
#           "producer",
#           "processor",
#           "licensor"
#         )
#       ),
#       list(
#         "url"= catalog_config$host_url,
#         "name"= catalog_config$host_name,
#         "roles" = list('host')
#       )
#     ),
#     "description" = theme_description,
#     "stac_version" = "1.0.0",
#     "stac_extensions" = list(
#       "https://stac-extensions.github.io/scientific/v1.0.0/schema.json",
#       "https://stac-extensions.github.io/item-assets/v1.0.0/schema.json",
#       "https://stac-extensions.github.io/table/v1.2.0/schema.json"
#     ),
#     "publications" = list(
#       "doi" = catalog_config$citation_doi,
#       "citation"= catalog_config$citation_text
#     )
#   )
#
#
#   dest <- destination_path
#   json <- file.path(dest, "collection.json")
#
#   jsonlite::write_json(theme,
#                        json,
#                        pretty=TRUE,
#                        auto_unbox=TRUE)
#   stac4cast::stac_validate(json)
# }




## ADD PLACEHOLDER FUNCTION FOR STAC4CAST TABLE BUILD
build_table_columns_full_bucket <- function(data_object,description_df){

  full_string_list <- strsplit(data_object$ToString(),'\n')[[1]]

  #create initial empty list
  init_list = vector(mode="list", length = data_object$num_cols)

  ## loop through parquet df and description information to build the list
  for (i in seq.int(1,data_object$num_cols)){
    list_items <- strsplit(full_string_list[i],': ')[[1]]
    col_list <- list(name = list_items[1],
                     type = list_items[2],
                     description = description_df[1,list_items[1]])

    init_list[[i]] <- col_list

  }
  return(init_list)
}

## WE DON'T USE THE FOLLOWING TWO FUNCITONS ANYMORE. KEEPING THEM FOR REFERENCE BUT DELETE EVENTUALLY
#' build_site_item <- function(theme_id,
#'                             start_date,
#'                             end_date,
#'                             destination_path,
#'                             theme_title,
#'                             collection_name,
#'                             thumbnail_link,
#'                             site_coords) {
#'
#'
#'   preset_keywords <- list("Forecasting", "NEON")
#'
#'   meta <- list(
#'     "stac_version"= "1.0.0",
#'     "stac_extensions"= list('https://stac-extensions.github.io/table/v1.2.0/schema.json'),
#'     "type"= "Feature",
#'     "id"= collection_name,
#'     "bbox"=
#'       list(-156.6194, 17.9696, -66.7987,  71.2824),
#'     "geometry"= list(
#'       "type"= "MultiPoint",
#'       "coordinates"= site_coords
#'     ),
#'     "properties"= list(
#'       #'description' = model_description,
#'       "description" = 'NEON Site Information',
#'       "start_datetime" = start_date,
#'       "end_datetime" = end_date,
#'       "providers"= list(
#'         list(
#'           "url"= "https://ecoforecast.org",
#'           "name"= "Ecoforecast Challenge",
#'           "roles"= list(
#'             "host"
#'           )
#'         )
#'       ),
#'       "license"= "CC0-1.0",
#'       "keywords"= c(preset_keywords),
#'       "table:columns" = build_site_metadata()
#'     ),
#'     "collection"= collection_name,
#'     "links"= list(
#'       list(
#'         "rel"= "catalog",
#'         'href' = '../catalog.json',
#'         "type"= "application/json",
#'         "title"= theme_title
#'       ),
#'       list(
#'         "rel"= "root",
#'         'href' = '../catalog.json',
#'         "type"= "application/json",
#'         "title"= "EFI Forecast Catalog"
#'       ),
#'       list(
#'         "rel"= "parent",
#'         'href' = '../catalog.json',
#'         "type"= "application/json",
#'         "title"= theme_title
#'       ),
#'       list(
#'         "rel"= "self",
#'         "href" = 'collection.json',
#'         "type"= "application/json",
#'         "title"= "Raw JSON Text"
#'       ),
#'       list(
#'         "rel" ="cite-as",
#'         "href"= "https://doi.org/10.1002/fee.2616",
#'         "title" = "citation"
#'       ),
#'       list(
#'         "rel"= "about",
#'         "href"= "https://projects.ecoforecast.org/neon4cast-docs/",
#'         "type"= "text/html",
#'         "title"= "NEON Forecast Challenge Documentation"
#'       ),
#'       list(
#'         "rel"= "describedby",
#'         "href"= "https://www.neonscience.org/field-sites/explore-field-sites",
#'         "title"= "Explore the NEON Field Sites",
#'         "type"= "text/html"
#'       )),
#'     "assets"= list(
#'       'data' = list(
#'         "href" = "https://raw.githubusercontent.com/eco4cast/neon4cast-targets/main/NEON_Field_Site_Metadata_20220412.csv",
#'         "type"= "text/plain",
#'         "title"= 'NEON Sites Table',
#'         "roles" = list('data'),
#'         "description"= 'Table that includes information for all NEON sites'
#'       ),
#'       "thumbnail" = list(
#'         "href"= thumbnail_link,
#'         "type"= "image/png",
#'         "title"= 'NEON Sites Image',
#'         "description"= 'Image describing the NEON sites',
#'         "roles" = list('thumbnail')
#'       )
#'     )
#'   )
#'
#'
#'   dest <- destination_path
#'   json <- file.path(dest, "collection.json")
#'
#'   jsonlite::write_json(meta,
#'                        json,
#'                        pretty=TRUE,
#'                        auto_unbox=TRUE)
#'   stac4cast::stac_validate(json)
#'
#'   rm(meta)
#' }

#
# build_site_metadata <- function(){
#   site_test <- read_csv("https://raw.githubusercontent.com/eco4cast/neon4cast-targets/main/NEON_Field_Site_Metadata_20220412.csv", col_types = cols())
#
#   schema_info <- sapply(site_test, class)
#
#   description_create <- data.frame(field_domain_id = 'domain identifier',
#                                    field_site_id = 'site identifier',
#                                    field_site_name = 'site name',
#                                    terrestrial = 'terrestrial theme indicator for site',
#                                    aquatics = 'aquatics theme indicator for site',
#                                    phenology = 'phenology theme indicator for site',
#                                    ticks = 'ticks theme indicator for site',
#                                    beetles = 'beetles theme indicator for site',
#                                    phenocam_code = 'code for phenocam',
#                                    phenocam_roi = 'phenocam region of interest',
#                                    phenocam_vegetation = 'phenocam vegetation identifier',
#                                    field_site_type = 'site theme type',
#                                    field_site_subtype = 'site theme subtype',
#                                    field_colocated_site = 'colocated field site',
#                                    field_site_host = 'site host organization',
#                                    field_site_url = 'site host organization URL',
#                                    field_nonneon_research_allowed = 'indicate whether non-NEON research is allowed at this site',
#                                    field_access_details = 'details for accessing the field site',
#                                    field_neon_field_operations_office = 'NEON field operations office',
#                                    field_latitude = 'field site latitude',
#                                    field_longitude = 'field site longitude',
#                                    field_geodetic_datum = 'geodetic datum for the field site',
#                                    field_utm_northing = 'northing UTM coordinates',
#                                    field_utm_easting = 'easting UTM coordinates',
#                                    field_utm_zone = 'UTM zone for field site',
#                                    field_site_county = 'county where field site is located',
#                                    field_site_state = 'state where field site is located',
#                                    field_site_country = 'country where field site is located',
#                                    field_mean_elevation_m = 'mean elevation of field site in meters',
#                                    field_minimum_elevation_m = 'minimum elevation of field site in meters',
#                                    field_maximum_elevation_m = 'maximum elevation of field site in meters',
#                                    field_mean_annual_temperature_C = 'mean annual temperaure of field site in degC',
#                                    field_mean_annual_precipitation_mm= 'mean annual precipitation of field site in mm',
#                                    field_dominant_wind_direction = 'the dominant wind direction at the field site',
#                                    field_mean_canopy_height_m = 'mean canpoy height at the field site in meters',
#                                    field_dominant_nlcd_classes = 'National Land Cover Database Class for field site',
#                                    field_dominant_plant_species = 'dominant plant species at field site',
#                                    field_usgs_huc = 'USGS Hydrologic Unit Code for the field site',
#                                    field_watershed_name = 'watershed name for the field site',
#                                    field_watershed_size_km2 = 'watershed size of field site in square kilometers',
#                                    field_lake_depth_mean_m = 'mean lake depth of field site in meters',
#                                    field_lake_depth_max_m = 'max lake depth of field site in meters',
#                                    field_tower_height_m = 'height of tower at field site in meters',
#                                    field_usgs_geology_unit = 'USGS geology unit for field site',
#                                    field_megapit_soil_family = 'megapit soil family for field site',
#                                    field_soil_subgroup = 'soild subgroup of field site',
#                                    field_avg_number_of_green_days = 'average number of green days at field site',
#                                    field_avg_green_increase_doy = 'day of year for average green increase at field site',
#                                    field_avg_green_max_doy = 'average day of year with maximum green at field site',
#                                    field_avg_green_decrease_doy = 'avergae day of year of green decrease at field site',
#                                    field_avg_green_min_doy = 'average day of year with minimum green at field site',
#                                    field_phenocams = 'details about phenocams located at each field site',
#                                    field_number_tower_levels = 'number of tower levels at field site',
#                                    neon_url = 'NEON URL for field site')
#
#
#
#
#
#   x <- purrr::map(seq.int(1:ncol(site_test)), function(i)
#     list(
#       "name" = names(site_test)[i],
#       'description'= description_create[,i],
#       'type' = schema_info[[i]]
#     )
#   )
#
#   return(x)
# }
