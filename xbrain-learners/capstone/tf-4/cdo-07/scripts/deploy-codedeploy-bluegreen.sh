#!/usr/bin/env bash
set -euo pipefail

environment="${1:?environment is required}"
service_key="${2:?service key is required}"
image_uri="${3:?image URI with digest is required}"

cluster="${ECS_CLUSTER:-tf4-cdo07-${environment}}"
ecs_service="${ECS_SERVICE_NAME:-tf4-cdo07-${environment}-${service_key}}"
container_name="${CONTAINER_NAME:-${service_key}}"
container_port="${CONTAINER_PORT:-8080}"
codedeploy_app="${CODEDEPLOY_APP:-tf4-cdo07-${environment}-${service_key}}"
codedeploy_group="${CODEDEPLOY_GROUP:-tf4-cdo07-${environment}-${service_key}}"

current_task_definition="$(
  aws ecs describe-services \
    --cluster "$cluster" \
    --services "$ecs_service" \
    --query 'services[0].taskDefinition' \
    --output text
)"

if [[ -z "$current_task_definition" || "$current_task_definition" == "None" ]]; then
  echo "::error title=ECS service not found::${ecs_service} was not found in cluster ${cluster}."
  exit 1
fi

task_definition_json="$(
  aws ecs describe-task-definition \
    --task-definition "$current_task_definition" \
    --query 'taskDefinition'
)"

if [[ "$(jq --arg container "$container_name" '[.containerDefinitions[].name] | index($container) != null' <<< "$task_definition_json")" != "true" ]]; then
  echo "::error title=Container not found::${container_name} was not found in ${current_task_definition}."
  exit 1
fi

new_task_definition="$(
  jq \
    --arg container "$container_name" \
    --arg image "$image_uri" \
    '
    .containerDefinitions |= map(
      if .name == $container then .image = $image else . end
    )
    | del(
        .taskDefinitionArn,
        .revision,
        .status,
        .requiresAttributes,
        .compatibilities,
        .registeredAt,
        .registeredBy
      )
    ' <<< "$task_definition_json"
)"

new_task_definition_arn="$(
  aws ecs register-task-definition \
    --cli-input-json "$new_task_definition" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text
)"

appspec="$(
  jq -n \
    --arg task_definition "$new_task_definition_arn" \
    --arg container "$container_name" \
    --argjson port "$container_port" \
    '{
      version: 1,
      Resources: [
        {
          TargetService: {
            Type: "AWS::ECS::Service",
            Properties: {
              TaskDefinition: $task_definition,
              LoadBalancerInfo: {
                ContainerName: $container,
                ContainerPort: $port
              }
            }
          }
        }
      ]
    }'
)"

revision_file="$(mktemp)"
jq -n --arg content "$appspec" '{
  revisionType: "AppSpecContent",
  appSpecContent: {
    content: $content
  }
}' > "$revision_file"

deployment_id="$(
  aws deploy create-deployment \
    --application-name "$codedeploy_app" \
    --deployment-group-name "$codedeploy_group" \
    --revision "file://${revision_file}" \
    --query 'deploymentId' \
    --output text
)"

aws deploy wait deployment-successful \
  --deployment-id "$deployment_id"

echo "Blue/green deployed ${ecs_service} to ${image_uri} with CodeDeploy deployment ${deployment_id}"
