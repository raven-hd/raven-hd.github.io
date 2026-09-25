(() => {
  const params = new URLSearchParams(location.search);
  const requestedView = params.get("view");
  const allowedViews = ["play", "rating", "tournament", "admin"];

  if (allowedViews.includes(requestedView)) {
    document.documentElement.dataset.initialView = requestedView;
  } else if (params.has("game") || params.has("watch")) {
    document.documentElement.dataset.initialView = "game";
  }
})();
