library(ggiraph)
library(patchwork)
library(tidyverse)
library(score4cast)
library(glue)

# Build a deterministic model_id -> color mapping so that a given model gets the
# same color across every panel/plot. Colors are keyed by model_id name (not by
# rank), so per-panel fct_reorder()ing does not change which color a model gets.
# Base hues are the validated colorblind-safe categorical palette; when there are
# more models than base hues we interpolate to keep the mapping deterministic.
model_palette <- function(model_ids) {
  models <- sort(unique(as.character(model_ids)))
  base_hues <- c("#2a78d6", "#eb6834", "#1baf7a", "#eda100",
                 "#e87ba4", "#008300", "#4a3aa7", "#e34948")
  n <- length(models)
  cols <- if (n <= length(base_hues)) {
    base_hues[seq_len(n)]
  } else {
    grDevices::colorRampPalette(base_hues)(n)
  }
  stats::setNames(cols, models)
}

forecast_ggobj <- function(df, ncol = NULL, show.legend = TRUE, pal = NULL) {

    df <- df |> collect()
    if (is.null(pal)) pal <- model_palette(df$model_id)

    df |>
    ggplot() +
    geom_point(aes(datetime, observation)) +
    geom_ribbon_interactive(aes(x = datetime, ymin = quantile02.5, ymax = quantile97.5,
                                fill = model_id, data_id = model_id, tooltip = model_id),
                            alpha = 0.2, show.legend=FALSE) +
    geom_line_interactive(aes(datetime, mean, col = model_id,
                              tooltip = model_id, data_id = model_id), show.legend=show.legend) +
    scale_color_manual(values = pal) +
    scale_fill_manual(values = pal) +
    labs(x = 'datetime', y = 'predicted') +
    facet_wrap(~site_id, scales = "free", ncol=ncol) +
    guides(x =  guide_axis(angle = 45)) +
    theme_bw()
}


forecast_plots <- function(df, ncol = NULL, show.legend = FALSE, height_svg = 4) {

  if(nrow(df)==0) return(NULL)

  ggobj <- forecast_ggobj(df, ncol, show.legend)
  girafe(ggobj = ggobj,
         width_svg = 8, height_svg = height_svg,
         options = list(
           opts_hover_inv(css = "opacity:0.20;"),
           opts_hover(css = "stroke-width:2;"),
           opts_zoom(max = 4)
         ))

}



by_model_id <- function(df, show.legend = FALSE, pal = NULL) {
  leaderboard <-
    df |>
    group_by(model_id) |>
    summarise(crps = mean(crps, na.rm=TRUE),
              #logs = mean(logs, na.rm=TRUE),
              .groups = "drop") |>
    collect() |>
    mutate(model_id = fct_rev(fct_reorder(model_id, crps)))

  if (is.null(pal)) pal <- model_palette(leaderboard$model_id)

  leaderboard |>
    pivot_longer(cols = c(crps), names_to="metric", values_to="score") |>

    ggplot(aes(x = model_id, y= score,  fill=model_id)) +
    geom_col_interactive(aes(tooltip = model_id, data_id = model_id),
                           show.legend = FALSE) +
    scale_fill_manual(values = pal) +
   # scale_y_log10() +
    coord_flip() +
    facet_wrap(~metric, scales='free') +
    theme_bw() +
   theme(axis.text.y = element_blank()) # don't show model_id twice

  }




by_reference_datetime <- function(df, show.legend = FALSE, pal = NULL) {
  leaderboard <-
    df |>
    group_by(model_id, reference_datetime) |>
    summarise(crps = mean(crps, na.rm=TRUE),
              #logs = mean(logs, na.rm=TRUE),
              .groups = "drop") |>
    mutate(reference_datetime = lubridate::as_datetime(reference_datetime)) |>
    collect() |>
    mutate(model_id = fct_rev(fct_reorder(model_id, crps)))

  if (is.null(pal)) pal <- model_palette(leaderboard$model_id)

  leaderboard |>
    pivot_longer(cols = c(crps), names_to="metric", values_to="score") |>

    ggplot(aes(x = reference_datetime, y= score,  col=model_id)) +
    geom_line_interactive(aes(tooltip = model_id, data_id = model_id),
                           show.legend = FALSE) +
    scale_color_manual(values = pal) +
    scale_y_log10() +
    facet_wrap(~metric, scales='free') +
    guides(x =  guide_axis(angle = 45)) +
    theme_bw()
}



by_horizon <- function(df, show.legend=FALSE, pal = NULL) {

  leaderboard2 <- df |>
  group_by(model_id, horizon) |>
  summarise(crps = mean(crps, na.rm=TRUE),
            #logs = mean(logs, na.rm=TRUE),
            .groups = "drop") |>
  collect() |>
  mutate(model_id = fct_rev(fct_reorder(model_id, crps)))  # sort by score

  if (is.null(pal)) pal <- model_palette(leaderboard2$model_id)

  leaderboard2 |>
    pivot_longer(cols = c(crps), names_to="metric", values_to="score") |>
    ggplot(aes(x = horizon, y= score,  col=model_id)) +
    geom_line_interactive(aes(tooltip = model_id, data_id = model_id),
                           show.legend = show.legend) +
    scale_color_manual(values = pal) +
    facet_wrap(~metric, scales='free') +
    scale_y_log10() +
    theme_bw()
}


horizon_filter <- function(df, horizon_cutoff=35, horizon_units="days") {
  df |>
    mutate(horizon =
             difftime(
               lubridate::as_datetime(datetime),
               lubridate::as_datetime(reference_datetime),
               units = horizon_units)
    ) |>
    filter(horizon <= horizon_cutoff, horizon > 0)
}

leaderboard_plots <- function(df,
                              var,
                              horizon_cutoff = 35,
                              horizon_units = "days",
                              show.legend=TRUE) {

  df <- df |> filter(variable == var) |> filter(!is.na(observation))
  df <- horizon_filter(df, horizon_cutoff, horizon_units)
  if(nrow(df)==0) return(NULL)

  # one shared model_id -> color map used by all three panels
  pal <- model_palette(df |> distinct(model_id) |> collect() |> pull(model_id))

  board1 <- by_model_id(df, show.legend = FALSE, pal = pal)
  board2 <- by_reference_datetime(df, show.legend = FALSE, pal = pal) + theme_bw()
  board3 <- by_horizon(df, show.legend = FALSE, pal = pal) + theme_bw()

  ggob <- board1 / board2 / board3 # patchwork stack

  girafe(
    ggobj = ggob,
    width_svg = 8,
    height_svg = 6,
    options = list(
      opts_hover_inv(css = "opacity:0.20;"),
      opts_hover(css = "stroke-width:2;"),
      opts_zoom(max = 4)
    )
  )

}
