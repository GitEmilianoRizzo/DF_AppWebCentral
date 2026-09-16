# ============================================
# DF Group - Backend API Dockerfile
# Multi-stage build for optimized image
# ============================================

# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

# Copy csproj and restore dependencies
COPY ["backend/DFGroup.Api/DFGroup.Api.csproj", "backend/DFGroup.Api/"]
RUN dotnet restore "backend/DFGroup.Api/DFGroup.Api.csproj"

# Copy source code and build
COPY backend/DFGroup.Api/. backend/DFGroup.Api/
WORKDIR "/src/backend/DFGroup.Api"
RUN dotnet build "DFGroup.Api.csproj" -c Release -o /app/build

# Stage 2: Publish
FROM build AS publish
RUN dotnet publish "DFGroup.Api.csproj" -c Release -o /app/publish /p:UseAppHost=false

# Stage 3: Runtime
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final
WORKDIR /app

# Install curl for healthcheck
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN adduser --disabled-password --gecos '' appuser

# Copy published app
COPY --from=publish /app/publish .

# Create logs directory
RUN mkdir -p /app/logs && chown -R appuser:appuser /app/logs

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Environment variables
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/api/health || exit 1

# Entry point
ENTRYPOINT ["dotnet", "DFGroup.Api.dll"]
