# Hetzner VPS (37.27.243.187) - Security & Infrastructure Roadmap

**Server:** `hetzner-arm` (dave@37.27.243.187:38291)  
**Status:** Phase A Complete - All critical issues resolved, user data recovered  
**Current Date:** June 11, 2025

## 🎯 MISSION STATEMENT
Complete security hardening, service optimization, and infrastructure automation for the Hetzner VPS while maintaining 100% uptime and data integrity.

---

## 🚨 CRITICAL ISSUES IDENTIFIED

### 1. Pangolin Authentication Error
- **Issue:** "The requests url is not found - /api/v1/auth/login" error on login page
- **Impact:** Potential authentication bypass or service failure
- **Priority:** URGENT - Fix immediately

### 2. Firewall Rules Cleanup Required  
- **Issue:** Multiple unused firewall rules for localhost-bound services
- **Ports to Remove:** 9443, 4180, 9091, 8000, 8788, 8443, 19090
- **Priority:** HIGH - Security best practice

---

## 📋 COMPREHENSIVE ROADMAP

### Phase 1: SECURITY & CRITICAL FIXES (Immediate - Week 1)

#### 🔥 **Priority 1.1: Critical Security Hardening**
- [ ] **Fix Pangolin API authentication error** - Debug /api/v1/auth/login endpoint failure
- [ ] **Clean up firewall rules** - Remove unused ports for localhost-bound services  
- [ ] **SSH key rotation audit** - Review current SSH access, rotate keys if needed
- [ ] **TLS certificate renewal verification** - Ensure automated renewal working
- [ ] **Docker socket security audit** - Verify no insecure Docker API exposure

#### 🛡️ **Priority 1.2: Service Security Review**
- [ ] **User privilege audit** - Review sudo access and service user permissions
- [ ] **RustDesk security evaluation** - Determine if external remote desktop access needed
- [ ] **Authentication flow testing** - Verify all services properly behind GitHub OAuth
- [ ] **Container security scan** - Check for vulnerable images or configurations

### Phase 2: INFRASTRUCTURE OPTIMIZATION (Week 2-3)

#### 🐳 **Priority 2.1: Container Migration to Dockge**
- [ ] **Move RustDesk to Dockge** - Simple compose file migration
- [ ] **Move Portainer to Dockge** - Standalone container migration  
- [ ] **Move Linkwarden to Dockge** - Database-dependent service migration
- [ ] **Plan Pangolin Stack migration** - Complex interconnected services strategy
- [ ] **Plan Authelia migration** - Authentication dependency management
- [ ] **Plan Traefik migration** - Core infrastructure zero-downtime strategy

#### ⚙️ **Priority 2.2: Service Optimization & Cleanup**
- [ ] **Set container resource limits** - CPU/memory constraints for all containers
- [ ] **Remove unused services** - Clean up zombie containers/services
- [ ] **Network optimization** - Review and optimize Docker network configurations
- [ ] **RustDesk usage analysis** - Get connection statistics, determine necessity
- [ ] **Service dependency mapping** - Document interconnections and requirements

### Phase 3: MONITORING & OBSERVABILITY (Week 3-4)

#### 📊 **Priority 3.1: Monitoring Implementation**
- [ ] **Resource monitoring setup** - CPU/RAM/Disk monitoring with alerts
- [ ] **Service health monitoring** - Uptime monitoring for all critical services
- [ ] **Log aggregation system** - Centralized logging for all services  
- [ ] **Security event monitoring** - Failed auth attempts, unusual access patterns
- [ ] **External uptime monitoring** - Third-party monitoring for public services

#### 🔍 **Priority 3.2: Observability Tools**
- [ ] **Dashboard creation** - Unified monitoring dashboard
- [ ] **Alert configuration** - Email/notification alerts for critical events
- [ ] **Performance metrics** - Baseline and trend analysis setup
- [ ] **Capacity planning** - Resource usage analysis and forecasting

### Phase 4: BACKUP & DISASTER RECOVERY (Week 4-5)

#### 💾 **Priority 4.1: Backup Strategy Implementation**  
- [ ] **Container volume backup** - Systematic backup of persistent data
- [ ] **Configuration backup automation** - Nginx configs, compose files, certificates
- [ ] **Database backup automation** - Regular dumps of all databases
- [ ] **Off-site backup setup** - Secure remote backup storage
- [ ] **Backup encryption** - Encrypt all backup data

#### 🔄 **Priority 4.2: Disaster Recovery**
- [ ] **Recovery procedure documentation** - Step-by-step restoration guides
- [ ] **Backup restoration testing** - Verify backup integrity and restore process
- [ ] **Infrastructure as Code** - Automated deployment scripts for reproducibility  
- [ ] **Failover planning** - Service continuity strategies
- [ ] **Recovery time objectives** - Define and test RTO/RPO metrics

### Phase 5: DOCUMENTATION & AUTOMATION (Week 5-6)

#### 📚 **Priority 5.1: Documentation Consolidation**
- [ ] **Service inventory documentation** - Complete catalog of all services
- [ ] **Runbook creation** - Step-by-step operational procedures
- [ ] **Dependency mapping** - Service interdependencies and requirements
- [ ] **Security procedures** - Access control and security maintenance guides
- [ ] **Remove redundant documentation** - Consolidate and clean up per user preference

#### 🤖 **Priority 5.2: Automation Implementation**
- [ ] **Automated deployment scripts** - Infrastructure as Code implementation
- [ ] **Configuration management** - Automated config deployment and updates
- [ ] **Update automation** - Automated security and system updates
- [ ] **Health check automation** - Automated service health verification
- [ ] **Certificate management automation** - Fully automated SSL certificate lifecycle

---

## 📈 QUICK WINS - Next 10 Steps (Ordered by Ease)

### 🟢 **EASY (1-2 commands, <30 minutes)**
1. **Clean up firewall rules** - `sudo ufw delete` unused ports
2. **Check TinyAuth configuration** - Verify GitHub OAuth settings  
3. **Audit RustDesk usage** - Check connection logs and necessity
4. **Review container resource usage** - `docker stats` analysis

### 🟡 **MODERATE (30 minutes - 2 hours)**  
5. **Fix Pangolin API authentication** - Debug /api/v1/auth/login endpoint
6. **Move RustDesk to Dockge** - Compose file migration
7. **Move Portainer to Dockge** - Standalone container move
8. **Set up basic monitoring** - Simple resource monitoring

### 🟠 **COMPLEX (2+ hours)**
9. **Backup strategy implementation** - Comprehensive backup solution
10. **Move Linkwarden to Dockge** - Database dependency migration

---

## 🎯 ACTION PLAN - Maximum 3 Items at a Time

### **IMMEDIATE BATCH 1** (Start Now)
1. **🚨 Fix Pangolin authentication error** - Critical service failure
2. **🔧 Clean up firewall rules** - Security best practice  
3. **🔍 Audit RustDesk necessity** - Determine if external access needed

### **BATCH 2** (After Batch 1 Complete)
1. **🔑 SSH key security audit** - Review access and rotate if needed
2. **🐳 Move RustDesk to Dockge** - First container migration
3. **📊 Basic monitoring setup** - Resource usage visibility

### **BATCH 3** (After Batch 2 Complete)  
1. **🐳 Move Portainer to Dockge** - Second container migration
2. **⚙️ Container resource limits** - Set CPU/memory constraints
3. **🔐 TLS certificate verification** - Ensure renewal automation

### **BATCH 4** (After Batch 3 Complete)
1. **💾 Container backup strategy** - Implement systematic backups
2. **🐳 Move Linkwarden to Dockge** - Complex migration
3. **📚 Service documentation** - Document current infrastructure

---

## 🏆 SUCCESS METRICS

- **Security:** Zero unauthorized access, all services properly authenticated
- **Availability:** 99.9% uptime for all critical services  
- **Recovery:** Sub-4-hour disaster recovery capability
- **Maintenance:** Automated updates and monitoring
- **Documentation:** Complete operational runbooks for all procedures

---

## 📞 ESCALATION & SUPPORT

- **ClaudePoint Checkpoints:** Create before each major change
- **Backup Verification:** Test restore procedures monthly
- **Security Reviews:** Quarterly comprehensive security audits
- **Documentation Updates:** Keep roadmap current with completed items

---

**Last Updated:** June 11, 2025  
**Next Review:** Weekly during active phases, monthly during maintenance

