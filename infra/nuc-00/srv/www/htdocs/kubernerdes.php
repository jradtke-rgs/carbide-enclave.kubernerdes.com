<?php

/**
 * @author      James Radtke <cloudxabide@gmail.com>
 * @version     1.0.2
 * @since       2025-08-16
 * @package     
 * @license     MIT
 *
 * @description:  This script was originally created to display the services exposed with 
 *                  type:LoadBalancer
 *                I then added top node and top pods
 *                Then, I opted to scan for available *.kubeconfig files and make them a selection
 *
 * Usage:         place this script in /var/www/html and your *.kubeconfig(s) in /var/www/.kube/
 *
 * Dependencies:  http server, php, php-yaml
 *                /var/www/html/, /var/www/.kube/ directory
 * 
 * Note/Warning:  This script is just intended for lab usage.  I would NOT do this on a 
 *                  production cluster, or in an environment with sensitive data. 
 *                Also, I am not nec. a "coder".  Use at your own risk.  I know that I do ;-)
 *
 *        Todo:  Need to figure out whether kubectl should be an full-path
 *        Note:  This was written using VI and Claude/Perplexity
 * Change log:
 * 2025-08-16 - v1.0.2: cleanup the "exec" of the kubectl command.  Also, added a section to display
 *                        Ingress(es)
 * 2025-04-20 - v1.0.1: All kinds of updates.  Added a section to allow selection of 
 *                        cluster (based on *.kubeconfig files)
 * 2025-01-29 - v1.0.0: Initial release
 */

$verboseTroubleshooting=0;
?>
<HTML>
<HEAD>
  <TITLE>Kubernerdes Homelab Clusters and Services | &#169 2025 </TITLE>
  <LINK REL="stylesheet" HREF="./styles.css" TYPE="text/css">
  <!-- <meta http-equiv="refresh" content="5" -->
<?php
// <!-- This section is located here as it provides the filename for the meta refresh tag -->
// Directory containing kubeconfig files
$kubeconfig_directory = '/srv/www/.kube';

// Holy carp this was tough to figure out... I had *assumed* that if a URL var was present and valid, that it was "set" 
//        - you have to implicitly set the var based on the $_GET call, apparently
if (isset($_GET['kubeconfig_filename_basename'])) {
  $kubeconfig_filename_basename = $_GET['kubeconfig_filename_basename'];
  $kubeconfig = $kubeconfig_directory . "/" . $kubeconfig_filename_basename;
  // echo "kubeconfig_filename_basename set to: $kubeconfig_filename_basename \n<BR>";
} else {
  $kubeconfig_filename_basename = "kubeconfig";
  $kubeconfig = $kubeconfig_directory . "/" . $kubeconfig_filename_basename;
  echo "kubeconfig_filename_basename was not set. Defaulting to \"kubeconfig\" <BR> \n";
}
echo "  <META http-equiv=\"refresh\" content=\"3; url=./kubernerdes.php?kubeconfig_filename_basename=$kubeconfig_filename_basename\">";
?> 
</HEAD>
<BODY>

<TABLE BORDER=1>
<TH colspan=2>Select a Kubernerdes Clusters</TH>
<TR><TD><span class="boldPara">Cluster Name</TD><TD><span class="boldPara">Kubeconfig</span></TD></TR>

<?php
// Find all files ending with .kubeconfig
$kubeconfig_files_fullpath = glob($kubeconfig_directory . '/*.kubeconfig');

// Cycle through all the *.kubeconfig files discovered (for-loop)
foreach ($kubeconfig_files_fullpath as $kubeconfig_file_fullpath) {
  $clusterName = '';
  $kubeconfig_filename_basename = basename($kubeconfig_file_fullpath);

  // Read the kubeconfig file
  $content = file_get_contents($kubeconfig_file_fullpath);
  if ($content === false) {
    // Could not read file, skip
    continue;
  }

  // Try to parse YAML using yaml_parse if available
  if (function_exists('yaml_parse')) {
    $parsed = @yaml_parse($content);
    if ($parsed && isset($parsed['clusters'][0]['name'])) {
      $clusterName = $parsed['clusters'][0]['name'];
    }
  } else {
    // Fallback: parse cluster name manually (very basic YAML parsing)
    // Look for the first occurrence of "name:" after a "clusters:" section
    $lines = explode("\n", $content);
    $inClusters = false;
    foreach ($lines as $line) {
      $trim = trim($line);
      if (strpos($trim, 'clusters:') === 0) {
        $inClusters = true;
        continue;
      }
      if ($inClusters && preg_match('/name:\s*(.+)/', $trim, $matches)) {
        $clusterName = $matches[1];
        break;
      }
    }
  }

  // ****************************
  if ($verboseTroubleshooting != 0) {
  // Troubleshooting
  echo "kubeconfig_file_fullpath $kubeconfig_file_fullpath \n <BR>";
  echo "kubeconfig_filename_basename $kubeconfig_filename_basename \n <BR>";
  echo "clusterName $clusterName \n <BR>";
  echo "<BR>";
  }
  // ****************************

  // Print the filename and cluster name
  echo "<TR>\n";
  echo "<TD> <A HREF=\"./kubernerdes.php?kubeconfig_filename_basename=" . $kubeconfig_filename_basename . "\">" . $clusterName . "</A></TD> <TD>" . basename($kubeconfig_filename_basename) . "</TD>";  
  echo "</TR>\n";

}
putenv ("KUBECONFIG=$kubeconfig");
// End of cycle (for-loop)
echo "</TABLE>\n";

echo "<BR> \n";

// This is cheating to get a reference to what cluster is being viewed.  I *should* extract it from the KUBECONFIG that is being used
$daClusterName = preg_replace('/\.kubeconfig$/', '', $kubeconfig);
echo "<TABLE><H2>Currently viewing Cluster: " . basename($daClusterName) . "</H2></TABLE> \n";

echo "<BR> \n";
// *************************************************************************
// This section will display the exposed services
echo "<!-- INCLUDE THE SERVICES OVERVIEW HERE -->\n";
$services_output = shell_exec('kubectl get services -A -o jsonpath=\'{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\t"}{.spec.ports[0].port}{"\n"}{end}\'');

$lines = explode("\n", $services_output);

// Initialize an array to store the parsed results
$parsed_hosts = array();

// Loop through each line
foreach ($lines as $line) {
    // Trim whitespace from the beginning and end of the line
    $line = trim($line);

    // Skip empty lines and comments
    if (empty($line) || $line[0] === '#') {
        continue;
    }

    // Split the line into parts
    $parts = preg_split('/\s+/', $line);

    // Ensure we have at least three parts (service, IP and port)
    if (count($parts) >= 3) {
        $service = $parts[0];
        $ip = $parts[1];
        $port = $parts[2];

        // Store the parsed values in the array
        $parsed_hosts[] = array(
            'service' => $service,
            'ip' => $ip,
            'port' => $port
        );
    }
}

echo "<TABLE border=1><TH COLSPAN=4>Kubernerdes Services and Endpoints </TH> \n";
// Print the parsed results
    echo "<TR>";
    echo "<TD><b>service name</TD>";
    echo "<TD><b>IP Address</TD> ";
    echo "<TD><b>port</TD>";
    echo "<TD><b>URL</TD>";
    echo "</TR>\n";

foreach ($parsed_hosts as $index => $host) {
    //echo "Entry " . ($index + 1) . ":\n";
    echo "<TR>";
    echo "<TD>" . $host['service'] . "</TD> ";
    echo "<TD>" . $host['ip'] . "</TD> ";
    echo "<TD>" . $host['port'] . "</TD> ";
    if ($host['port'] == '443') {
      $http_prefix="https";
    } else {
      $http_prefix="http";
    }
    // This next line would be for 80/443 (HTTP/HTTPS) URLs only
    //echo "<TD><A HREF=" . $http_prefix . "://" . $host['ip'] . "/  target=pane" . $index . ">" . $http_prefix . "://" . $host['ip'] . " </A></TD>" ;
    // I discovered I had to include the port number in the URL for non-standard ports (like 3000 for grafana)
    echo "<TD><A HREF=" . $http_prefix . "://" . $host['ip'] . ":" . $host['port'] . " target=pane" . $index . ">" . $http_prefix . "://" . $host['ip'] . ":" . $host['port'] . " </A></TD>" ;
    echo "</TR>\n";
}
echo "</TABLE>\n";

echo "<BR> \n";
// *************************************************************************
//  This section will display all the ingress hosts that are defined
echo "<!-- INCLUDE THE INGRESSES OVERVIEW HERE -->\n";

/**
 * Kubernetes Ingress to HTML Links Generator
 * 
 * This script runs kubectl to get all ingress resources across all namespaces,
 * parses the output, and generates HTML links based on port configuration.
 */

function getIngressData() {
    // Run kubectl command to get all ingress resources in JSON format
    $command = 'kubectl get ingress --all-namespaces -o json 2>/dev/null';
    $output = shell_exec($command);
    
    if ($output === null) {
        throw new Exception("Failed to execute kubectl command. Make sure kubectl is installed and configured.");
    }
    
    $data = json_decode($output, true);
    if ($data === null) {
        throw new Exception("Failed to parse kubectl JSON output.");
    }
    
    return $data;
}

function parseIngressRules($ingress) {
    $links = [];
    $namespace = $ingress['metadata']['namespace'];
    $name = $ingress['metadata']['name'];
    
    if (!isset($ingress['spec']['rules']) || !is_array($ingress['spec']['rules'])) {
        return $links;
    }
    
    foreach ($ingress['spec']['rules'] as $rule) {
        if (!isset($rule['host'])) {
            continue;
        }
        
        $host = $rule['host'];
        $exposedPorts = [];
        
        // Check if TLS is configured for this host
        $hasTls = false;
        if (isset($ingress['spec']['tls']) && is_array($ingress['spec']['tls'])) {
            foreach ($ingress['spec']['tls'] as $tls) {
                if (isset($tls['hosts']) && in_array($host, $tls['hosts'])) {
                    $hasTls = true;
                    $exposedPorts[] = 443; // HTTPS port
                    break;
                }
            }
        }
        
        // For HTTP traffic, ingress typically exposes port 80
        if (isset($rule['http']['paths']) && is_array($rule['http']['paths']) && !empty($rule['http']['paths'])) {
            $exposedPorts[] = 80; // HTTP port
        }
        
        // Check for custom ports in annotations (common for some ingress controllers)
        if (isset($ingress['metadata']['annotations'])) {
            $annotations = $ingress['metadata']['annotations'];
            
            // Check for nginx ingress custom ports
            if (isset($annotations['nginx.ingress.kubernetes.io/server-snippet'])) {
                preg_match_all('/listen\s+(\d+)/', $annotations['nginx.ingress.kubernetes.io/server-snippet'], $matches);
                if (!empty($matches[1])) {
                    foreach ($matches[1] as $port) {
                        $exposedPorts[] = (int)$port;
                    }
                }
            }
            
            // Check for custom HTTP/HTTPS ports in other common annotations
            if (isset($annotations['kubernetes.io/ingress.class'])) {
                // Some ingress controllers use specific annotations for custom ports
                foreach ($annotations as $key => $value) {
                    if (preg_match('/port/', $key) && is_numeric($value)) {
                        $exposedPorts[] = (int)$value;
                    }
                }
            }
        }
        
        // Remove duplicate ports
        $exposedPorts = array_unique($exposedPorts);
        
        // If no specific ports found, assume standard ports based on TLS config
        if (empty($exposedPorts)) {
            if ($hasTls) {
                $exposedPorts = [443]; // HTTPS only
            } else {
                $exposedPorts = [80]; // HTTP only
            }
        }
        
        // Generate links based on exposed ports
        foreach ($exposedPorts as $port) {
            $protocol = determineProtocol($port, $hasTls);
            $url = $protocol . '://' . $host;
            
            // Add port to URL if it's not standard
            if (($protocol === 'http' && $port != 80) || ($protocol === 'https' && $port != 443)) {
                $url .= ':' . $port;
            }
            
            $links[] = [
                'url' => $url,
                'host' => $host,
                'port' => $port,
                'protocol' => $protocol,
                'namespace' => $namespace,
                'name' => $name,
                'has_tls' => $hasTls
            ];
        }
    }
    
    return $links;
}

function determineProtocol($port, $hasTls) {
    // Use http for port 80, https for port 443 and any other port
    if ($port == 80) {
        return 'http';
    } else {
        return 'https';
    }
}

function generateHtmlTable($allLinks) {
    if (empty($allLinks)) {
        return "<p>No ingress resources found.</p>";
    }
    
    //$html .= "<table class=\"ingress-table\">\n";
    $html .= "<table border=1>\n";
    $html .= "  <th colspan=7>Kubernerdes Ingress(es)</th>\n";
    $html .= "    <tr>\n";
    $html .= "      <th>Namespace</th>\n";
    $html .= "      <th>Ingress Name</th>\n";
    $html .= "      <th>Host</th>\n";
    $html .= "      <th>URL</th>\n";
    $html .= "      <th>Port</th>\n";
    $html .= "      <th>Protocol</th>\n";
    $html .= "      <th>TLS</th>\n";
    $html .= "    </tr>\n";
    
    // Sort links by namespace, then by name
    usort($allLinks, function($a, $b) {
        $namespaceCompare = strcmp($a['namespace'], $b['namespace']);
        if ($namespaceCompare !== 0) {
            return $namespaceCompare;
        }
        return strcmp($a['name'], $b['name']);
    });
    
    foreach ($allLinks as $link) {
        $tlsIndicator = $link['has_tls'] ? '🔒 Yes' : 'No';
        $protocolUpper = strtoupper($link['protocol']);
        
        $html .= "    <tr>\n";
        $html .= "      <td>{$link['namespace']}</td>\n";
        $html .= "      <td>{$link['name']}</td>\n";
        $html .= "      <td>{$link['host']}</td>\n";
        $html .= "      <td><a href=\"{$link['url']}\" target=\"_blank\">{$link['url']}</a></td>\n";
        $html .= "      <td>{$link['port']}</td>\n";
        $html .= "      <td>{$protocolUpper}</td>\n";
        $html .= "      <td>{$tlsIndicator}</td>\n";
        $html .= "    </tr>\n";
    }
    
    $html .= "  </body>\n";
    $html .= "</table>\n";
    
    return $html;
}

function addStyling() {
    return "
<style>
    body {
        font-family: Arial, sans-serif;
        margin: 20px;
        background-color: #f5f5f5;
    }
    .error {
        color: #d32f2f;
        background-color: #ffebee;
        padding: 10px;
        border-radius: 4px;
        border-left: 4px solid #d32f2f;
    }
</style>
";
}

// Main execution
try {
    // Get ingress data from kubectl
    $ingressData = getIngressData();
    
    $allLinks = [];
    
    // Process each ingress resource
    if (isset($ingressData['items']) && is_array($ingressData['items'])) {
        foreach ($ingressData['items'] as $ingress) {
            $links = parseIngressRules($ingress);
            $allLinks = array_merge($allLinks, $links);
        }
    }
    
    echo generateHtmlTable($allLinks);
    
} catch (Exception $e) {
    echo "<!DOCTYPE html>\n";
    echo "<html>\n<head>\n";
    echo "    <title>Error - Kubernetes Ingress Links</title>\n";
    echo addStyling();
    echo "</head>\n<body>\n";
    echo "<div class=\"error\">";
    echo "<h2>Error</h2>";
    echo "<p>" . htmlspecialchars($e->getMessage()) . "</p>";
    echo "</div>";
    echo "</body>\n</html>";
}

echo "<BR> \n";
// *************************************************************************
//  This section will display "top nodes"
echo "<!-- INCLUDE THE TOP NODES HERE -->\n";
echo "<TABLE border=1><TH COLSPAN=4>Kubernerdes Top Nodes </TH> \n";
echo "<TR><TD colspan=4>\n";
// Run kubectl top nodes
$cmd = "kubectl top nodes";
exec($cmd, $output_top_nodes, $status);

if ($status === 0) {
    echo "<pre>\n";
    foreach ($output_top_nodes as $line) {
        echo htmlspecialchars($line) . "\n";
    }
    echo "</pre>";
} else {
    echo "Error running 'kubectl top nodes' command.";
}
echo "</TD></TR> </TABLE>\n";

echo "<BR> \n";
// *************************************************************************
//  This section will display "top pods"
echo "<!-- INCLUDE THE TOP PODS HERE -->\n";
echo "<TABLE border=1><TH COLSPAN=4>Kubernerdes Top Pods </TH> \n";
echo "<TR><TD colspan=4>\n";
// Run kubectl top pods 
$cmd = "kubectl top pods -A ";
exec($cmd, $output_top_pods, $status);

if ($status === 0) {
    echo "<pre>\n";
    foreach ($output_top_pods as $line) {
        echo htmlspecialchars($line) . "\n";
    }
    echo "</pre>";
} else {
    echo "Error running 'kubectl top pods' command.";
}
echo "</TD></TR> </TABLE>\n";
?>

</BODY>
</HTML>
