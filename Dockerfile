# CI/build container, NOT a VPS runtime container.
# For reproducible CI pin the Flutter image tag used by your project instead of 'stable'.
FROM ghcr.io/cirruslabs/flutter:stable
WORKDIR /app
COPY pubspec.yaml analysis_options.yaml ./
RUN flutter pub get
COPY . .
CMD ["flutter", "analyze"]
