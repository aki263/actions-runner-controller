package actionssummerwindnet

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-logr/logr"
	"gomodules.xyz/jsonpatch/v2"
	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

const (
	AnnotationKeyTokenExpirationDate = "actions-runner-controller/token-expires-at"
)

// +kubebuilder:webhook:path=/mutate-runner-set-pod,mutating=true,failurePolicy=ignore,groups="",resources=pods,verbs=create,versions=v1,name=mutate-runner-pod.webhook.actions.summerwind.dev,sideEffects=None,admissionReviewVersions=v1beta1

type PodRunnerTokenInjector struct {
	client.Client

	Name         string
	Log          logr.Logger
	Recorder     record.EventRecorder
	GitHubClient *MultiGitHubClient
	decoder      admission.Decoder
}

func (t *PodRunnerTokenInjector) Handle(ctx context.Context, req admission.Request) admission.Response {
	var pod corev1.Pod
	err := t.decoder.Decode(req, &pod)
	if err != nil {
		t.Log.Error(err, "Failed to decode request object")
		return admission.Errored(http.StatusBadRequest, err)
	}

	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}

	var runnerContainer *corev1.Container
	// Loop through containers to find the one named "runner"
	for i := range pod.Spec.Containers {
		// Correctly get a pointer to the container in the slice
		if pod.Spec.Containers[i].Name == "runner" {
			runnerContainer = &pod.Spec.Containers[i]
			break // Found the runner container, exit loop
		}
	}

	if runnerContainer == nil {
		// Log if the runner container is not found and return an empty response.
		t.Log.V(1).Info("Pod does not have a 'runner' container, skipping token injection", "podName", pod.Name, "podNamespace", pod.Namespace)
		return newEmptyResponse()
	}

	enterprise, okEnterprise := getEnv(runnerContainer, EnvVarEnterprise)
	repo, okRepo := getEnv(runnerContainer, EnvVarRepo)
	org, okOrg := getEnv(runnerContainer, EnvVarOrg)
	if !okRepo || !okOrg || !okEnterprise {
		return newEmptyResponse()
	}

	ghc, err := t.GitHubClient.InitForRunnerPod(ctx, &pod)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}

	rt, err := ghc.GetRegistrationToken(context.Background(), enterprise, org, repo, pod.Name)
	if err != nil {
		t.Log.Error(err, "Failed to get new registration token")
		return admission.Errored(http.StatusInternalServerError, err)
	}

	ts := rt.GetExpiresAt().Format(time.RFC3339)

	updated := mutatePod(&pod, *rt.Token)

	updated.Annotations[AnnotationKeyTokenExpirationDate] = ts

	forceRunnerPodRestartPolicyNever(updated)

	buf, err := json.Marshal(updated)
	if err != nil {
		t.Log.Error(err, "Failed to encode new object")
		return admission.Errored(http.StatusInternalServerError, err)
	}

	res := admission.PatchResponseFromRaw(req.Object.Raw, buf)
	return res
}

func getEnv(container *corev1.Container, key string) (string, bool) {
	for _, env := range container.Env {
		if env.Name == key {
			return env.Value, true
		}
	}

	return "", false
}

func (t *PodRunnerTokenInjector) InjectDecoder(d admission.Decoder) error {
	t.decoder = d
	return nil
}

func newEmptyResponse() admission.Response {
	pt := admissionv1.PatchTypeJSONPatch
	return admission.Response{
		Patches: []jsonpatch.Operation{},
		AdmissionResponse: admissionv1.AdmissionResponse{
			Allowed:   true,
			PatchType: &pt,
		},
	}
}

func (r *PodRunnerTokenInjector) SetupWithManager(mgr ctrl.Manager) error {
	name := "pod-runner-token-injector"
	if r.Name != "" {
		name = r.Name
	}

	r.Recorder = mgr.GetEventRecorderFor(name)

	mgr.GetWebhookServer().Register("/mutate-runner-set-pod", &admission.Webhook{Handler: r})

	return nil
}
