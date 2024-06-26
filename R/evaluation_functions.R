#' Evaluate forecasts (from scores) across different evaluation groupings
#'
#' @param scores A data frame of forecast scores to be summarized. Must have
#'  columns that match the output from `covidHubUtils::score_forecasts()` and
#'  include scores for a baseline model.
#' @param grouping_variables A character vector specifying the type of grouping
#'  to be used in evaluation. Options are `season`, `horizon`, `forecast_week`,
#'   `location`.
#' @param baseline_name A character string specifying the name of the baseline
#'  model to calculate relative metrics against
#' @param us_only A boolean specifying whether to summarize metrics for the US
#'  national level only or just states
#'
#' @return A data frame of summarized forecast score metrics across all
#'  provided forecasts
#' @export
#'
#' @examples
#' @importFrom rlang .data

evaluate_flu_scores <- function(scores, grouping_variables, baseline_name,
                                us_only = FALSE) {
  if (isFALSE("location" %in% grouping_variables)) {
    if (us_only) {
      scores <- dplyr::filter(scores, .data$location == "US")
    } else {
      scores <- dplyr::filter(scores, .data$location != "US")
    }
  }

  if ("season" %in% grouping_variables & isFALSE("season" %in% names(scores))) {
    scores <- scores |>
      dplyr::mutate(season = ifelse(.data$forecast_date < as.Date("2022-08-01"),
        "2021-2022", "2022-2023"
      ))
  }

  summarized_scores_all <- scores |>
    dplyr::group_by(.data$model, dplyr::across(dplyr::all_of(grouping_variables))) |>
    dplyr::summarize(
      wis = mean(.data$wis), mae = mean(.data$abs_error),
      cov50 = mean(.data$coverage_50), cov95 = mean(.data$coverage_95)
    )

  summarized_scores_baseline <- scores |>
    dplyr::filter(.data$model == baseline_name) |>
    dplyr::group_by(.data$model, dplyr::across(dplyr::all_of(grouping_variables))) |>
    dplyr::summarize(base_wis = mean(.data$wis), base_mae = mean(.data$abs_error)) |>
    dplyr::ungroup() |>
    dplyr::select(-.data$model)

  if (is.null(grouping_variables)) {
    summarized_scores_all <- summarized_scores_all |>
      dplyr::mutate(
        base_wis = unique(summarized_scores_baseline$base_wis),
        base_mae = unique(summarized_scores_baseline$base_mae)
      )
  } else {
    summarized_scores_all <- summarized_scores_all |>
      dplyr::left_join(summarized_scores_baseline, by = grouping_variables)
  }

  summarized_scores_all |>
    dplyr::mutate(
      rwis = dplyr::case_when(
        base_wis != 0 ~ .data$wis / .data$base_wis,
        base_wis == 0 & .data$wis == 0 ~ 1,
        base_wis == 0 & .data$wis != 0 ~ Inf
      ),
      rmae = dplyr::case_when(
        base_mae != 0 ~ .data$mae / .data$base_mae,
        base_mae == 0 & .data$mae == 0 ~ 1,
        base_mae == 0 & .data$mae != 0 ~ Inf
      )
    ) |>
    dplyr::select(-.data$base_wis, -.data$base_mae) |>
    dplyr::group_by(dplyr::across(dplyr::all_of(grouping_variables))) |>
    dplyr::mutate(dplyr::across(dplyr::where(is.numeric), round, digits = 3)) |>
    dplyr::arrange(.data$wis, .by_group = TRUE)
}


#' Plot summarized metrics against forecast_date, with option to plot averaged
#' truth data on the same graph
#'
#' @param summarized_scores A data frame of summarized scores. Must contain one
#'  row per model and horizon week combination plus a `horizon` column
#' @param model_names An ordered vector of model names
#' @param model_colors An ordered vector of model colors. Must match with
#'  `model_names` order
#' @param y_var A string specifying which metric to plot as the y-variable
#' @param h An integer specifying the horizon of the desired metric to plot
#' @param main A string specifying the plot title. Defaults to NULL.
#' @param truth_data A data frame of truth data to plot in the same figure.
#'  Defaults to `NULL`. If provided must contain target_end_date and value
#'  columns.
#' @param truth_scaling A numeric specifying a multiplier for the truth values
#'  so that it fits nicely on the graph.
#'
#' @return A scatter plot (with observations connected by lines) of the
#'  specified summary metric vs forecast date
#' @export
#'
#' @examples
#' @importFrom rlang .data

plot_evaluated_scores_forecast_date <- function(summarized_scores, model_names,
                                                model_colors, y_var = "wis",
                                                h = 1, main = NULL,
                                                truth_data = NULL,
                                                truth_scaling = 0.125) {
  data_to_plot <- summarized_scores |>
    dplyr::filter(.data$horizon == h)

  if (!is.null(truth_data)) {
    date_range <- lubridate::interval(
      min(data_to_plot$forecast_date),
      max(data_to_plot$forecast_date)
    )

    truth_to_plot <- truth_data |>
      dplyr::mutate(target_end_date = .data$target_end_date - lubridate::days(5)) |>
      dplyr::filter(.data$target_end_date %within% date_range) |>
      dplyr::group_by(.data$model, .data$target_end_date) |>
      dplyr::summarize(value = mean(.data$value))

    truth_to_plot <- truth_to_plot |>
      dplyr::mutate(value = dplyr::case_when(
        y_var == "wis" ~ .data$value * truth_scaling,
        y_var == "mae" ~ .data$value * truth_scaling,
        (y_var == "cov95" | y_var == "cov50") &
          .data$target_end_date < as.Date("2022-08-01") ~
          -0.15 * .data$value / max(truth_to_plot$value) + 1,
        (y_var == "cov95" | y_var == "cov50") &
          .data$target_end_date > as.Date("2022-08-01") ~
          -0.5 * .data$value / max(truth_to_plot$value) + 1,
        .default = .data$value * truth_scaling
      ))
  }

  if (y_var == "wis") {
    y_lab <- "average wis"
    gg <- ggplot2::ggplot(data_to_plot,
      mapping = ggplot2::aes(
        x = .data$forecast_date, y = .data$wis,
        shape = .data$model, group = .data$model
      )
    ) +
      ggplot2::coord_cartesian(ylim = c(0, sum(stats::quantile(data_to_plot$wis,
        prob = c(0.5, 0.99)
      ))))
  } else if (y_var == "mae") {
    y_lab <- "mae"
    gg <- ggplot2::ggplot(data_to_plot,
      mapping = ggplot2::aes(
        x = .data$forecast_date, y = .data$mae,
        shape = .data$model, group = .data$model
      )
    ) +
      ggplot2::coord_cartesian(ylim = c(0, sum(stats::quantile(data_to_plot$mae,
        prob = c(0.5, 0.99)
      ))))
  } else if (y_var == "cov95") {
    y_lab <- "average PI coverage"
    truth_data <- NULL
    gg <- ggplot2::ggplot(data_to_plot,
      mapping = ggplot2::aes(
        x = .data$forecast_date, y = .data$cov95,
        shape = .data$model, group = .data$model
      )
    ) +
      ggplot2::coord_cartesian(ylim = c(0, 1.05)) +
      ggplot2::geom_hline(ggplot2::aes(yintercept = 0.95))
  } else if (y_var == "cov50") {
    y_lab <- "average PI coverage"
    truth_data <- NULL
    gg <- ggplot2::ggplot(data_to_plot,
      mapping = ggplot2::aes(
        x = .data$forecast_date, y = .data$cov50,
        shape = .data$model, group = .data$model
      )
    ) +
      ggplot2::coord_cartesian(ylim = c(0, 1.05)) +
      ggplot2::geom_hline(ggplot2::aes(yintercept = 0.50))
  }

  if (!is.null(truth_data)) {
    gg +
      ggplot2::geom_point(truth_to_plot,
        mapping = ggplot2::aes(
          x = .data$target_end_date, y = .data$value,
          shape = .data$model, group = .data$model
        ),
        col = "black"
      ) +
      ggplot2::geom_line(truth_to_plot,
        mapping = ggplot2::aes(
          x = .data$target_end_date, y = .data$value,
        shape = .data$model, group = .data$model
        ), col = "black"
      ) +
      ggplot2::geom_point(mapping = ggplot2::aes(col = .data$model)) +
      ggplot2::geom_line(mapping = ggplot2::aes(col = .data$model)) +
      ggplot2::scale_x_date(
        name = "forecast date", date_breaks = "2 months",
        date_labels = "%b '%y"
      ) +
      ggplot2::scale_y_continuous(
        name = y_lab,
        sec.axis = ggplot2::sec_axis(
          trans = ~ . / truth_scaling,
          name = "average target data"
        )
      ) +
      ggplot2::scale_color_manual(breaks = model_names, values = model_colors) +
      ggplot2::labs(title = main) +
      ggplot2::theme_bw()
  } else {
    gg +
      ggplot2::geom_point(mapping = ggplot2::aes(col = .data$model), alpha = 0.8) +
      ggplot2::geom_line(mapping = ggplot2::aes(col = .data$model), alpha = 0.8) +
      ggplot2::scale_x_date(
        name = "forecast date", date_breaks = "2 months",
        date_labels = "%b '%y"
      ) +
      ggplot2::scale_color_manual(breaks = model_names, values = model_colors) +
      ggplot2::labs(title = main, y = y_lab) +
      ggplot2::theme_bw()
  }
}



#' Plot averaged truth against forecast date
#'
#' @param truth_data A data frame of truth data. Must contain a target_end_date
#'  column
#' @param date_range An ordered string vector giving the range of dates to plot
#' @param main A string specifying the plot title. Defaults to NULL.
#' @param plot_color A string specifying the color that the truth should be
#'  plotted as. Defaults to "black".
#'
#' @return A scatter plot (with observations connected by lines) of the truth
#'  data vs forecast date
#' @export
#'
#' @examples
#' @importFrom rlang .data

plot_flu_truth <- function(truth_data, date_range = NULL, main = "truth data",
                           plot_color = "black") {
  truth_to_plot <- truth_data |>
    dplyr::mutate(forecast_date = .data$target_end_date - lubridate::days(5))

  if (!is.null(date_range)) {
    dates_to_plot <- lubridate::interval(
      as.Date(date_range[1]),
      as.Date(date_range[2])
    )

    truth_to_plot <- truth_to_plot |>
      dplyr::filter(.data$forecast_date %within% dates_to_plot)
  }

  truth_to_plot <- truth_to_plot |>
    dplyr::group_by(.data$forecast_date) |>
    dplyr::summarize(value = mean(.data$value))

  truth_to_plot |>
    ggplot2::ggplot(
      mapping = ggplot2::aes(x = .data$forecast_date, y = .data$value),
      col = plot_color, alpha = 0.8
    ) +
    ggplot2::geom_point() +
    ggplot2::geom_line() +
    ggplot2::scale_x_date(
      name = "forecast date", date_breaks = "2 months",
      date_labels = "%b '%y"
    ) +
    ggplot2::coord_cartesian(ylim = c(0, max(truth_to_plot$value) * 1.1)) +
    ggplot2::labs(title = main, y = "average value") +
    ggplot2::theme_bw()
}
