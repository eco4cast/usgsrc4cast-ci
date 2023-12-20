s3 <- arrow::s3_bucket(bucket = "bio230121-bucket01/vera4cast/metadata/model_id/", # update from vera4cast?
                       endpoint_override = "renc.osn.xsede.org", anonymous = TRUE)

d1 <- arrow::open_dataset(s3, format = "json") |> dplyr::collect()

model_type <- unnest(d1[[3]], cols = names(d1[[3]]))$type

model_type[which(stringr::str_detect(model_type, "mpirical"))] <- "Empirical"

tibble::tibble(model_type = model_type) |>
ggplot(aes(x = model_type)) +
  geom_bar() +
  labs(x = "Model Type", y = "Number submitting forecasts") +
  theme_bw()
