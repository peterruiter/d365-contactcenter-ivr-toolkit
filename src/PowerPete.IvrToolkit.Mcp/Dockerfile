FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS runtime
WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build
WORKDIR /src
COPY src/PowerPete.IvrToolkit.Mcp/PowerPete.IvrToolkit.Mcp.csproj PowerPete.IvrToolkit.Mcp/
RUN dotnet restore PowerPete.IvrToolkit.Mcp/PowerPete.IvrToolkit.Mcp.csproj
COPY src/PowerPete.IvrToolkit.Mcp/ PowerPete.IvrToolkit.Mcp/
COPY build/customapis.json ../build/customapis.json
RUN dotnet publish PowerPete.IvrToolkit.Mcp/PowerPete.IvrToolkit.Mcp.csproj -c Release -o /publish

FROM runtime AS final
COPY --from=build /publish .
# Container Apps probes this. Keep it unauthenticated.
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:8080/health || exit 1
ENTRYPOINT ["dotnet", "PowerPete.IvrToolkit.Mcp.dll"]
