--
-- PostgreSQL database dump
--

-- Dumped from database version 17.2 (Debian 17.2-1.pgdg110+1)
-- Dumped by pg_dump version 17.2 (Debian 17.2-1.pgdg110+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: clusters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clusters (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    name character varying(100) NOT NULL,
    description text,
    config text,
    prometheus_url text,
    in_cluster boolean DEFAULT false,
    cluster_agent boolean DEFAULT false,
    cluster_agent_token_hash character varying(64),
    cluster_agent_public_key character varying(64),
    cluster_agent_private_key text,
    is_default boolean DEFAULT false,
    enable boolean DEFAULT true
);


--
-- Name: clusters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clusters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clusters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clusters_id_seq OWNED BY public.clusters.id;


--
-- Name: general_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.general_settings (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    ai_agent_enabled boolean DEFAULT false NOT NULL,
    ai_provider character varying(50) DEFAULT 'openai'::character varying NOT NULL,
    ai_model character varying(255) DEFAULT 'gpt-4o-mini'::character varying NOT NULL,
    ai_api_key text,
    ai_base_url character varying(500),
    ai_max_tokens integer DEFAULT 16384,
    kubectl_enabled boolean DEFAULT true NOT NULL,
    kubectl_image character varying(255) DEFAULT 'zzde/kubectl:latest'::character varying NOT NULL,
    node_terminal_image character varying(255) DEFAULT 'busybox:latest'::character varying NOT NULL,
    cluster_agent_image character varying(255) DEFAULT 'ghcr.io/kite-org/kite:latest'::character varying NOT NULL,
    plugin_catalog_url character varying(2048),
    enable_analytics boolean DEFAULT false NOT NULL,
    analytics_installation_id character varying(32),
    analytics_last_attempt_at timestamp with time zone,
    enable_version_check boolean DEFAULT true NOT NULL,
    password_login_disabled boolean DEFAULT false NOT NULL,
    enable_mfa boolean DEFAULT true NOT NULL,
    enable_passkey_login boolean DEFAULT true NOT NULL,
    login_prompt text,
    jwt_secret text,
    global_sidebar_preference text
);


--
-- Name: general_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.general_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: general_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.general_settings_id_seq OWNED BY public.general_settings.id;


--
-- Name: helm_repositories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.helm_repositories (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    name character varying(255) NOT NULL,
    url character varying(1024) NOT NULL,
    plain_http boolean DEFAULT false NOT NULL,
    username character varying(255),
    password text
);


--
-- Name: helm_repositories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.helm_repositories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: helm_repositories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.helm_repositories_id_seq OWNED BY public.helm_repositories.id;


--
-- Name: ldap_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ldap_settings (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    enabled boolean DEFAULT false NOT NULL,
    server_url character varying(500),
    use_starttls boolean DEFAULT false NOT NULL,
    bind_dn character varying(500),
    bind_password text,
    user_base_dn character varying(500),
    user_filter character varying(500) DEFAULT '(uid=%s)'::character varying,
    username_attribute character varying(100) DEFAULT 'uid'::character varying,
    display_name_attribute character varying(100) DEFAULT 'cn'::character varying,
    group_base_dn character varying(500),
    group_filter character varying(500) DEFAULT '(member=%s)'::character varying,
    group_name_attribute character varying(100) DEFAULT 'cn'::character varying
);


--
-- Name: ldap_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ldap_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ldap_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ldap_settings_id_seq OWNED BY public.ldap_settings.id;


--
-- Name: o_auth_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.o_auth_providers (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    name character varying(100) NOT NULL,
    client_id character varying(255) NOT NULL,
    client_secret text NOT NULL,
    auth_url character varying(255),
    token_url character varying(255),
    user_info_url character varying(255),
    scopes character varying(255),
    issuer character varying(255),
    enabled boolean DEFAULT true,
    username_claim character varying(255),
    groups_claim character varying(255),
    allowed_groups text
);


--
-- Name: o_auth_providers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.o_auth_providers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: o_auth_providers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.o_auth_providers_id_seq OWNED BY public.o_auth_providers.id;


--
-- Name: passkey_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.passkey_credentials (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    user_id bigint NOT NULL,
    name character varying(100) NOT NULL,
    credential_id character varying(512) NOT NULL,
    credential text NOT NULL,
    last_used_at timestamp without time zone
);


--
-- Name: passkey_credentials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passkey_credentials_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: passkey_credentials_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.passkey_credentials_id_seq OWNED BY public.passkey_credentials.id;


--
-- Name: pending_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_sessions (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    session_id character varying(64) NOT NULL,
    provider character varying(32) NOT NULL,
    ai_model character varying(255) DEFAULT ''::character varying NOT NULL,
    system_prompt text,
    messages text,
    tool_calls text,
    tool_results text,
    next_tool_index bigint DEFAULT 0 NOT NULL,
    iteration bigint DEFAULT 0 NOT NULL,
    user_id bigint DEFAULT 0 NOT NULL,
    cluster_name character varying(255) DEFAULT ''::character varying NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: pending_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pending_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pending_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pending_sessions_id_seq OWNED BY public.pending_sessions.id;


--
-- Name: plugin_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugin_settings (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    plugin_id character varying(64) NOT NULL,
    data text
);


--
-- Name: plugin_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plugin_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plugin_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plugin_settings_id_seq OWNED BY public.plugin_settings.id;


--
-- Name: plugins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugins (
    id character varying(64) NOT NULL,
    enabled boolean,
    version character varying(128) NOT NULL,
    digest character varying(64) NOT NULL,
    download_url text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: resource_histories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_histories (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    cluster_name character varying(100) NOT NULL,
    resource_type character varying(255) NOT NULL,
    resource_name character varying(255) NOT NULL,
    namespace character varying(100),
    operation_type character varying(50) NOT NULL,
    operation_source character varying(20) DEFAULT 'manual'::character varying NOT NULL,
    resource_yaml text,
    previous_yaml text,
    success boolean,
    error_message text,
    operator_id bigint NOT NULL
);


--
-- Name: resource_histories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resource_histories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resource_histories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resource_histories_id_seq OWNED BY public.resource_histories.id;


--
-- Name: resource_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_templates (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    name character varying(255) NOT NULL,
    description text,
    yaml text
);


--
-- Name: resource_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resource_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resource_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resource_templates_id_seq OWNED BY public.resource_templates.id;


--
-- Name: role_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_assignments (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    role_id bigint NOT NULL,
    subject_type character varying(20) NOT NULL,
    subject character varying(255) NOT NULL
);


--
-- Name: role_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.role_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.role_assignments_id_seq OWNED BY public.role_assignments.id;


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    name character varying(100) NOT NULL,
    description text,
    is_system boolean DEFAULT false NOT NULL,
    clusters text,
    resources text,
    namespaces text,
    verbs text
);


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.roles_id_seq OWNED BY public.roles.id;


--
-- Name: scheduled_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scheduled_tasks (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    cluster_name character varying(100) NOT NULL,
    type character varying(100) NOT NULL,
    key character varying(255) NOT NULL,
    name character varying(255),
    creator_id bigint,
    enabled boolean DEFAULT false NOT NULL,
    schedule_type character varying(20) DEFAULT 'interval'::character varying NOT NULL,
    interval_minutes bigint DEFAULT 60 NOT NULL,
    schedule_time character varying(5) DEFAULT '03:00'::character varying NOT NULL,
    payload text,
    last_run_at timestamp with time zone,
    next_run_at timestamp with time zone,
    last_success_at timestamp with time zone,
    last_error text,
    locked_at timestamp with time zone,
    locked_by character varying(255),
    lock_until timestamp with time zone
);


--
-- Name: scheduled_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scheduled_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scheduled_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scheduled_tasks_id_seq OWNED BY public.scheduled_tasks.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    username character varying(50) NOT NULL,
    password character varying(255),
    name character varying(100),
    avatar_url text,
    provider character varying(50) DEFAULT 'password'::character varying,
    o_id_c_groups text,
    last_login_at timestamp without time zone,
    enabled boolean DEFAULT true,
    sub character varying(255),
    mfa_enabled boolean DEFAULT false NOT NULL,
    mfa_secret text,
    api_key text,
    sidebar_preference text
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: clusters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clusters ALTER COLUMN id SET DEFAULT nextval('public.clusters_id_seq'::regclass);


--
-- Name: general_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.general_settings ALTER COLUMN id SET DEFAULT nextval('public.general_settings_id_seq'::regclass);


--
-- Name: helm_repositories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helm_repositories ALTER COLUMN id SET DEFAULT nextval('public.helm_repositories_id_seq'::regclass);


--
-- Name: ldap_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ldap_settings ALTER COLUMN id SET DEFAULT nextval('public.ldap_settings_id_seq'::regclass);


--
-- Name: o_auth_providers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.o_auth_providers ALTER COLUMN id SET DEFAULT nextval('public.o_auth_providers_id_seq'::regclass);


--
-- Name: passkey_credentials id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passkey_credentials ALTER COLUMN id SET DEFAULT nextval('public.passkey_credentials_id_seq'::regclass);


--
-- Name: pending_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_sessions ALTER COLUMN id SET DEFAULT nextval('public.pending_sessions_id_seq'::regclass);


--
-- Name: plugin_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_settings ALTER COLUMN id SET DEFAULT nextval('public.plugin_settings_id_seq'::regclass);


--
-- Name: resource_histories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_histories ALTER COLUMN id SET DEFAULT nextval('public.resource_histories_id_seq'::regclass);


--
-- Name: resource_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_templates ALTER COLUMN id SET DEFAULT nextval('public.resource_templates_id_seq'::regclass);


--
-- Name: role_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments ALTER COLUMN id SET DEFAULT nextval('public.role_assignments_id_seq'::regclass);


--
-- Name: roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles ALTER COLUMN id SET DEFAULT nextval('public.roles_id_seq'::regclass);


--
-- Name: scheduled_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_tasks ALTER COLUMN id SET DEFAULT nextval('public.scheduled_tasks_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: clusters clusters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clusters
    ADD CONSTRAINT clusters_pkey PRIMARY KEY (id);


--
-- Name: general_settings general_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.general_settings
    ADD CONSTRAINT general_settings_pkey PRIMARY KEY (id);


--
-- Name: helm_repositories helm_repositories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helm_repositories
    ADD CONSTRAINT helm_repositories_pkey PRIMARY KEY (id);


--
-- Name: ldap_settings ldap_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ldap_settings
    ADD CONSTRAINT ldap_settings_pkey PRIMARY KEY (id);


--
-- Name: o_auth_providers o_auth_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.o_auth_providers
    ADD CONSTRAINT o_auth_providers_pkey PRIMARY KEY (id);


--
-- Name: passkey_credentials passkey_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passkey_credentials
    ADD CONSTRAINT passkey_credentials_pkey PRIMARY KEY (id);


--
-- Name: pending_sessions pending_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_sessions
    ADD CONSTRAINT pending_sessions_pkey PRIMARY KEY (id);


--
-- Name: plugin_settings plugin_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugin_settings
    ADD CONSTRAINT plugin_settings_pkey PRIMARY KEY (id);


--
-- Name: plugins plugins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugins
    ADD CONSTRAINT plugins_pkey PRIMARY KEY (id);


--
-- Name: resource_histories resource_histories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_histories
    ADD CONSTRAINT resource_histories_pkey PRIMARY KEY (id);


--
-- Name: resource_templates resource_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_templates
    ADD CONSTRAINT resource_templates_pkey PRIMARY KEY (id);


--
-- Name: role_assignments role_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT role_assignments_pkey PRIMARY KEY (id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: scheduled_tasks scheduled_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_tasks
    ADD CONSTRAINT scheduled_tasks_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_clusters_cluster_agent_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clusters_cluster_agent_token_hash ON public.clusters USING btree (cluster_agent_token_hash);


--
-- Name: idx_clusters_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_clusters_name ON public.clusters USING btree (name);


--
-- Name: idx_helm_repositories_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_helm_repositories_name ON public.helm_repositories USING btree (name);


--
-- Name: idx_o_auth_providers_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_o_auth_providers_name ON public.o_auth_providers USING btree (name);


--
-- Name: idx_passkey_credentials_credential_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_passkey_credentials_credential_id ON public.passkey_credentials USING btree (credential_id);


--
-- Name: idx_passkey_credentials_last_used_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_passkey_credentials_last_used_at ON public.passkey_credentials USING btree (last_used_at);


--
-- Name: idx_passkey_credentials_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_passkey_credentials_user_id ON public.passkey_credentials USING btree (user_id);


--
-- Name: idx_pending_sessions_cluster_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_sessions_cluster_name ON public.pending_sessions USING btree (cluster_name);


--
-- Name: idx_pending_sessions_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_sessions_expires_at ON public.pending_sessions USING btree (expires_at);


--
-- Name: idx_pending_sessions_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pending_sessions_session_id ON public.pending_sessions USING btree (session_id);


--
-- Name: idx_pending_sessions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_sessions_user_id ON public.pending_sessions USING btree (user_id);


--
-- Name: idx_plugin_settings_plugin_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_plugin_settings_plugin_id ON public.plugin_settings USING btree (plugin_id);


--
-- Name: idx_resource_histories_lookup_with_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_histories_lookup_with_time ON public.resource_histories USING btree (cluster_name, resource_type, resource_name, namespace, created_at DESC);


--
-- Name: idx_resource_histories_operation_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_histories_operation_source ON public.resource_histories USING btree (operation_source);


--
-- Name: idx_resource_histories_operation_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_histories_operation_type ON public.resource_histories USING btree (operation_type);


--
-- Name: idx_resource_histories_operator_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_histories_operator_id ON public.resource_histories USING btree (operator_id);


--
-- Name: idx_resource_templates_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_resource_templates_name ON public.resource_templates USING btree (name);


--
-- Name: idx_role_assignments_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_assignments_role_id ON public.role_assignments USING btree (role_id);


--
-- Name: idx_role_assignments_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_assignments_subject ON public.role_assignments USING btree (subject, subject_type);


--
-- Name: idx_roles_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_roles_name ON public.roles USING btree (name);


--
-- Name: idx_scheduled_tasks_cluster_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_cluster_name ON public.scheduled_tasks USING btree (cluster_name);


--
-- Name: idx_scheduled_tasks_cluster_type_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_scheduled_tasks_cluster_type_key ON public.scheduled_tasks USING btree (cluster_name, type, key);


--
-- Name: idx_scheduled_tasks_creator_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_creator_id ON public.scheduled_tasks USING btree (creator_id);


--
-- Name: idx_scheduled_tasks_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_enabled ON public.scheduled_tasks USING btree (enabled);


--
-- Name: idx_scheduled_tasks_last_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_last_run_at ON public.scheduled_tasks USING btree (last_run_at);


--
-- Name: idx_scheduled_tasks_lock_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_lock_until ON public.scheduled_tasks USING btree (lock_until);


--
-- Name: idx_scheduled_tasks_next_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_next_run_at ON public.scheduled_tasks USING btree (next_run_at);


--
-- Name: idx_scheduled_tasks_schedule_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_schedule_type ON public.scheduled_tasks USING btree (schedule_type);


--
-- Name: idx_scheduled_tasks_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_tasks_type ON public.scheduled_tasks USING btree (type);


--
-- Name: idx_users_last_login_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_last_login_at ON public.users USING btree (last_login_at);


--
-- Name: idx_users_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_name ON public.users USING btree (name);


--
-- Name: idx_users_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_provider ON public.users USING btree (provider);


--
-- Name: idx_users_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_sub ON public.users USING btree (sub);


--
-- Name: idx_users_username; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_username ON public.users USING btree (username);


--
-- Name: resource_histories fk_resource_histories_operator; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_histories
    ADD CONSTRAINT fk_resource_histories_operator FOREIGN KEY (operator_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: role_assignments fk_roles_assignments; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_assignments
    ADD CONSTRAINT fk_roles_assignments FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

